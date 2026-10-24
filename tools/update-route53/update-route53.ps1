#Requires -Version 5.1
<#
.SYNOPSIS
    Points a Route 53 A record at the public IPv4 address of the current EC2 instance.

.DESCRIPTION
    Reads the instance public IP from IMDSv2 and UPSERTs it into the configured
    hosted zone. Intended to run unattended at instance startup, so every setting
    can come from a config file or environment variable instead of the command line.

    Settings are resolved in this order (first match wins):
      1. Command line parameters
      2. Environment variables  ROUTE53_ZONE_ID, ROUTE53_RECORD_NAME, ROUTE53_TTL
      3. config.json next to this script (see config.example.json)

.EXAMPLE
    .\update-route53.ps1 -ZoneId Z0123456789ABCDEFGHIJ -RecordName host.example.com

.EXAMPLE
    .\update-route53.ps1
    Uses config.json / environment variables. This is how the startup launcher runs it.
#>
[CmdletBinding()]
param(
    [string]$ZoneId,
    [string]$RecordName,
    [int]$Ttl,
    [string]$AwsProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ImdsBase = 'http://169.254.169.254/latest'

# PowerShell wraps native stderr in an ErrorRecord and writes its own trace
# ("At line:N char:N", "+ CategoryInfo ...") around the real message. Keep only
# the lines the program actually printed.
function Format-NativeStdErr {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $noise = @(
        '^\s*\+',                  # source-extract and +CategoryInfo/+FullyQualifiedErrorId lines
        '^\s*At line:\d+',         # location line for inline script blocks
        '^\s*At .+:\d+ char:\d+',  # location line for script files
        '^\s*\S+ :\s*$'            # the bare "aws.exe : " record header
    )

    $kept = $Text -split '\r?\n' | Where-Object {
        $line = $_
        if ([string]::IsNullOrWhiteSpace($line)) { return $false }
        foreach ($pattern in $noise) {
            if ($line -match $pattern) { return $false }
        }
        return $true
    }

    return ($kept -join [Environment]::NewLine).Trim()
}

# Runs the AWS CLI and returns its exit code, stdout and stderr.
# stderr is redirected to a file and the preference relaxed to 'Continue' for the
# call: under 'Stop' a native command writing to stderr raises a terminating
# NativeCommandError before $LASTEXITCODE can even be read.
function Invoke-Aws {
    param([string[]]$Arguments)

    $errFile = [System.IO.Path]::GetTempFileName()
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $stdout = (& aws @Arguments 2>$errFile | Out-String)
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previous

        $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = $stdout.Trim()
            StdErr   = Format-NativeStdErr -Text $stderr
        }
    }
    finally {
        $ErrorActionPreference = $previous
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ConfigFile {
    $path = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $path) {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    return $null
}

function Resolve-Setting {
    param(
        [string]$Value,
        [string]$EnvName,
        [string]$ConfigKey,
        $Config,
        [switch]$Required
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }

    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv }

    if ($null -ne $Config -and $Config.PSObject.Properties.Name -contains $ConfigKey) {
        $fromConfig = $Config.$ConfigKey
        if (-not [string]::IsNullOrWhiteSpace([string]$fromConfig)) { return [string]$fromConfig }
    }

    if ($Required) {
        throw "Missing setting '$ConfigKey'. Set it with -$ConfigKey, the $EnvName environment variable, or config.json next to this script."
    }
    return $null
}

function Invoke-Imds {
    param([string]$Path, [string]$Token)

    return Invoke-RestMethod -Method GET -Uri "$ImdsBase/$Path" `
        -Headers @{ 'X-aws-ec2-metadata-token' = $Token } -TimeoutSec 5
}

function Get-InstancePublicIp {
    Write-Host 'Resolving public IPv4 address from instance metadata...'

    try {
        $token = Invoke-RestMethod -Method PUT -Uri "$ImdsBase/api/token" `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' } -TimeoutSec 5
    }
    catch {
        throw "Instance metadata service is not reachable, so this does not look like an EC2 instance. ($($_.Exception.Message))"
    }

    try {
        $publicIp = ([string](Invoke-Imds -Path 'meta-data/public-ipv4' -Token $token)).Trim()
    }
    catch {
        throw "Instance metadata has no public-ipv4 entry: the instance has no public IPv4 address. ($($_.Exception.Message))"
    }

    if ($publicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw "Instance metadata returned an unexpected public IPv4 address: '$publicIp'"
    }

    return $publicIp
}

function Invoke-Main {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw 'AWS CLI not found on PATH. Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'
    }

    $config = Get-ConfigFile

    $ZoneId     = Resolve-Setting -Value $ZoneId     -EnvName 'ROUTE53_ZONE_ID'     -ConfigKey 'ZoneId'     -Config $config -Required
    $RecordName = Resolve-Setting -Value $RecordName -EnvName 'ROUTE53_RECORD_NAME' -ConfigKey 'RecordName' -Config $config -Required
    $AwsProfile = Resolve-Setting -Value $AwsProfile -EnvName 'AWS_PROFILE'         -ConfigKey 'AwsProfile' -Config $config

    if (-not $PSBoundParameters.ContainsKey('Ttl')) {
        $ttlSetting = Resolve-Setting -EnvName 'ROUTE53_TTL' -ConfigKey 'Ttl' -Config $config
        $Ttl = if ($ttlSetting) { [int]$ttlSetting } else { 60 }
    }

    $publicIp = Get-InstancePublicIp

    Write-Host "Public IPv4 address: $publicIp"
    Write-Host "Updating $RecordName (A, TTL $Ttl) in hosted zone $ZoneId"

    $changeBatch = [ordered]@{
        Comment = 'Auto-update A record on instance startup'
        Changes = @(
            [ordered]@{
                Action            = 'UPSERT'
                ResourceRecordSet = [ordered]@{
                    Name            = $RecordName
                    Type            = 'A'
                    TTL             = $Ttl
                    ResourceRecords = @(@{ Value = $publicIp })
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    # The AWS CLI needs the batch as a file: inline JSON is unreliable to quote on Windows.
    $batchFile = Join-Path ([System.IO.Path]::GetTempPath()) "route53-change-batch-$PID.json"
    try {
        Set-Content -LiteralPath $batchFile -Value $changeBatch -Encoding ASCII

        $awsArgs = @('route53', 'change-resource-record-sets',
            '--hosted-zone-id', $ZoneId,
            '--change-batch', "file://$batchFile",
            '--output', 'json')
        if ($AwsProfile) { $awsArgs += @('--profile', $AwsProfile) }

        $result = Invoke-Aws -Arguments $awsArgs
        if ($result.ExitCode -ne 0) {
            $detail = if ($result.StdErr) { $result.StdErr } else { $result.StdOut }
            throw "aws route53 change-resource-record-sets failed (exit code $($result.ExitCode)).`n$detail"
        }

        Write-Host "Done. $RecordName -> $publicIp"
    }
    finally {
        Remove-Item -LiteralPath $batchFile -Force -ErrorAction SilentlyContinue
    }
}

try {
    Invoke-Main
}
catch {
    # Keep the failure readable: output usually ends up in a log nobody is watching.
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

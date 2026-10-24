#Requires -Version 5.1
<#
.SYNOPSIS
    Opens the AWS Management Console in a browser using the current CLI credentials.

.DESCRIPTION
    Exchanges the active credentials for a federation sign-in token and opens the
    resulting console URL. Works both on a workstation (AWS CLI SSO / profile
    credentials) and on an EC2 instance (instance role from IMDSv2).

.EXAMPLE
    .\open-aws-console.ps1

.EXAMPLE
    .\open-aws-console.ps1 -Region eu-west-1 -AwsProfile my-sso-profile
#>
[CmdletBinding()]
param(
    [string]$Region,
    [string]$AwsProfile,

    # Console page to land on, e.g. 'https://console.aws.amazon.com/s3/home'
    [string]$Destination,

    # Print the URL instead of launching a browser.
    [switch]$PrintOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ImdsBase = 'http://169.254.169.254/latest'
$SigninUrl = 'https://signin.aws.amazon.com/federation'

Add-Type -AssemblyName System.Web

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

function Test-Imds {
    try {
        $null = Invoke-RestMethod -Method PUT -Uri "$ImdsBase/api/token" `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' } -TimeoutSec 2
        return $true
    }
    catch {
        return $false
    }
}

function Get-ImdsCredential {
    $token = Invoke-RestMethod -Method PUT -Uri "$ImdsBase/api/token" `
        -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '21600' } -TimeoutSec 5
    $headers = @{ 'X-aws-ec2-metadata-token' = $token }

    $roleName = Invoke-RestMethod -Uri "$ImdsBase/meta-data/iam/security-credentials/" -Headers $headers -TimeoutSec 5
    if ([string]::IsNullOrWhiteSpace($roleName)) {
        throw 'No IAM role is attached to this instance, so there are no credentials to federate with.'
    }

    $creds = Invoke-RestMethod -Uri "$ImdsBase/meta-data/iam/security-credentials/$roleName" -Headers $headers -TimeoutSec 5
    return [pscustomobject]@{
        AccessKeyId     = $creds.AccessKeyId
        SecretAccessKey = $creds.SecretAccessKey
        SessionToken    = $creds.Token
    }
}

function Get-CliCredential {
    param([string]$AwsProfile)

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw 'AWS CLI not found on PATH. Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'
    }

    $awsArgs = @('configure', 'export-credentials', '--format', 'process')
    if ($AwsProfile) { $awsArgs += @('--profile', $AwsProfile) }

    $result = Invoke-Aws -Arguments $awsArgs
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.StdErr) { $result.StdErr } else { $result.StdOut }
        throw "Could not export AWS credentials. Run 'aws sso login' or check your profile.`n$detail"
    }

    $session = $result.StdOut | ConvertFrom-Json
    return [pscustomobject]@{
        AccessKeyId     = $session.AccessKeyId
        SecretAccessKey = $session.SecretAccessKey
        SessionToken    = $session.SessionToken
    }
}

function Get-DefaultRegion {
    param([string]$AwsProfile)

    foreach ($candidate in @($env:AWS_REGION, $env:AWS_DEFAULT_REGION)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }

    if (Get-Command aws -ErrorAction SilentlyContinue) {
        $awsArgs = @('configure', 'get', 'region')
        if ($AwsProfile) { $awsArgs += @('--profile', $AwsProfile) }
        $result = Invoke-Aws -Arguments $awsArgs
        if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
            return $result.StdOut
        }
    }

    return 'us-east-1'
}

function Invoke-Main {
    if ($AwsProfile) { $env:AWS_PROFILE = $AwsProfile }

    if (Test-Imds) {
        Write-Host 'Detected EC2 environment - using instance metadata for credentials'
        $credential = Get-ImdsCredential
    }
    else {
        Write-Host 'Detected local environment - using AWS CLI credentials'
        $credential = Get-CliCredential -AwsProfile $AwsProfile
    }

    if ([string]::IsNullOrWhiteSpace($credential.SessionToken)) {
        throw 'Federated console sign-in needs temporary credentials (with a session token). Use an SSO profile, an assumed role, or an instance role.'
    }

    if (-not $Region) { $Region = Get-DefaultRegion -AwsProfile $AwsProfile }
    if (-not $Destination) { $Destination = "https://console.aws.amazon.com/console/home?region=$Region" }

    $sessionJson = [ordered]@{
        sessionId    = $credential.AccessKeyId
        sessionKey   = $credential.SecretAccessKey
        sessionToken = $credential.SessionToken
    } | ConvertTo-Json -Compress

    # SessionDuration is deliberately omitted: the federation endpoint rejects it when
    # the session is built from temporary credentials, which is always the case here.
    $tokenRequest = '{0}?Action=getSigninToken&Session={1}' -f $SigninUrl,
        [System.Web.HttpUtility]::UrlEncode($sessionJson)

    try {
        $signinToken = (Invoke-RestMethod -Uri $tokenRequest).SigninToken
    }
    catch {
        # The endpoint answers 400 with an empty body for rejected credentials,
        # so say what that actually means rather than echoing the status code.
        throw "The AWS federation endpoint rejected these credentials ($($_.Exception.Message)). They are most likely expired - refresh them (e.g. 'aws sso login') and try again."
    }

    if ([string]::IsNullOrWhiteSpace($signinToken)) {
        throw 'The AWS federation endpoint did not return a sign-in token.'
    }

    $federatedUrl = '{0}?Action=login&Issuer={1}&Destination={2}&SigninToken={3}' -f $SigninUrl,
        [System.Web.HttpUtility]::UrlEncode('aws-tools'),
        [System.Web.HttpUtility]::UrlEncode($Destination),
        [System.Web.HttpUtility]::UrlEncode($signinToken)

    if ($PrintOnly) {
        Write-Output $federatedUrl
    }
    else {
        Write-Host "Opening AWS Console for region $Region..."
        Start-Process $federatedUrl
    }
}

try {
    Invoke-Main
}
catch {
    # Keep the failure readable: this is usually launched by double-click.
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

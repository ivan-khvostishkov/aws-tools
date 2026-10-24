# aws-tools

Small, self-contained helper tools for day-to-day AWS work. Every tool is a
directory you can copy anywhere and run in place — no installer, no runtime
beyond the AWS CLI.

| Tool | What it does | How it is normally started |
| --- | --- | --- |
| [`open-aws-console`](tools/open-aws-console) | Opens the AWS Management Console in your browser, signed in with the credentials the AWS CLI already has | Manually — double-click `open-aws-console.cmd` on Windows (desktop shortcut), `open-aws-console.command` on macOS |
| [`update-route53`](tools/update-route53) | Points a Route 53 `A` record at the public IPv4 address of the current EC2 instance | Automatically — `update-route53.cmd` from the Windows startup folder |

## Layout

```
tools/
  open-aws-console/
    open-aws-console.cmd      Windows launcher (double-click; bypasses the PS execution policy)
    open-aws-console.ps1      Windows implementation
    open-aws-console.command  macOS launcher (double-click from Finder)
    open-aws-console.sh       macOS / Linux implementation
  update-route53/
    update-route53.cmd        Windows launcher (startup folder; bypasses the PS execution policy)
    update-route53.ps1        Windows implementation
    update-route53.sh         macOS / Linux implementation
    config.example.json       Copy to config.json and fill in
scripts/
  build.sh                    Assembles dist/
```

File names are lowercase `kebab-case` with no spaces or reserved characters, so
the same tree checks out cleanly on Windows, macOS and Linux. `.gitattributes`
keeps `.cmd`/`.ps1` files CRLF and `.sh`/`.command` files LF on every platform.

### Why a `.cmd` next to each `.ps1`

Windows blocks `.ps1` files by default (`Restricted` execution policy), and
double-clicking a `.ps1` opens it in an editor rather than running it. The `.cmd`
launcher is what you double-click or point a shortcut at: it invokes PowerShell
with `-NoProfile -ExecutionPolicy Bypass -File …` so the script runs without
changing any machine-wide policy. It also prefers `pwsh.exe` (PowerShell 7+) and
falls back to `powershell.exe` (5.1).

## Requirements

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
  (2.9 or newer, for `aws configure export-credentials`)
- Windows: PowerShell 5.1 (built in) or PowerShell 7+
- macOS / Linux: `bash`, `curl`, `jq`

## Building

```sh
./scripts/build.sh
```

This produces `dist/aws-tools/` with one directory per tool, a `README.md` and a
`VERSION` stamp. The `build` GitHub Actions workflow runs the same script on
every push to `main` and uploads `dist/aws-tools` as the `aws-tools` artifact,
which GitHub serves as `aws-tools.zip`.

## Credentials

Both tools use whatever credentials the environment already provides:

- On an **EC2 instance**, the instance role via IMDSv2.
- On a **workstation**, the active AWS CLI profile (`AWS_PROFILE`, or `--profile`
  / `-AwsProfile`). For SSO profiles run `aws sso login` first.

Nothing is written to disk except the temporary Route 53 change batch, which is
deleted when the tool finishes.

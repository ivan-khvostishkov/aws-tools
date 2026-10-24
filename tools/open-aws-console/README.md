# open-aws-console

Opens the AWS Management Console in your browser, already signed in with the
credentials the AWS CLI is configured with. Useful when you authenticate with
IAM Identity Center (SSO) or an assumed role and do not want to click through a
sign-in portal.

It works by exchanging your temporary credentials for a sign-in token at the AWS
federation endpoint, then opening the resulting console URL.

## Usage

### Windows

Double-click `open-aws-console.cmd`, or make it reachable from the desktop:

1. Right-click `open-aws-console.cmd` → **Show more options** → **Send to** →
   **Desktop (create shortcut)**.
2. Rename the shortcut to something like *Open AWS Console*.
3. Double-click it whenever you need the console.

Create the shortcut rather than moving the file — the launcher expects
`open-aws-console.ps1` to sit next to it. Shortcuts keep that intact.

The `.cmd` wrapper exists because Windows refuses to run `.ps1` files under the
default execution policy; it calls PowerShell with `-ExecutionPolicy Bypass` for
this one script only.

You can also run it from a terminal:

```bat
open-aws-console.cmd -Region eu-west-1 -AwsProfile my-sso-profile
```

Or call the script directly:

```powershell
.\open-aws-console.ps1 -PrintOnly
```

| Parameter | Description |
| --- | --- |
| `-Region` | Console region to land in. Default: the configured AWS region, else `us-east-1`. |
| `-AwsProfile` | AWS CLI profile to take credentials from. |
| `-Destination` | Console page to open, e.g. `https://console.aws.amazon.com/s3/home`. |
| `-PrintOnly` | Print the sign-in URL instead of opening a browser. |

### macOS

Double-click `open-aws-console.command` in Finder (it is a thin wrapper around
`open-aws-console.sh`). If Finder refuses to run it, restore the executable bit:

```sh
chmod +x open-aws-console.command open-aws-console.sh
```

### macOS / Linux

```sh
./open-aws-console.sh --region eu-west-1 --profile my-sso-profile
./open-aws-console.sh --print
```

| Option | Description |
| --- | --- |
| `--region REGION` | Console region to land in. |
| `--profile NAME` | AWS CLI profile to take credentials from. |
| `--destination URL` | Console page to open. |
| `--print` | Print the sign-in URL instead of opening a browser. |

The browser is launched with `open` (macOS), `xdg-open` (Linux) or `wslview`
(WSL), whichever is available.

## Credentials

- **EC2 instance** — detected automatically via IMDSv2; the instance role is used.
- **Workstation** — `aws configure export-credentials` on the active profile.
  Run `aws sso login` first if the SSO session has expired.

Federated console sign-in requires *temporary* credentials. A plain IAM user
access key has no session token and will be rejected with a clear error; use an
SSO profile, an assumed role, or an instance role instead.

## Notes

- The sign-in token is short-lived and is never written to disk.
- `SessionDuration` is deliberately not sent to the federation endpoint: it is
  only valid for long-term IAM user credentials, and this tool always federates
  from a session token. The console session instead inherits the lifetime of the
  underlying temporary credentials.

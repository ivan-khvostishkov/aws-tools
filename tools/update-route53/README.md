# update-route53

Reads the public IPv4 address of the current EC2 instance from instance metadata
(IMDSv2) and `UPSERT`s it as an `A` record in a Route 53 hosted zone. Run it at
instance startup and a stable DNS name always points at the instance, even
without an Elastic IP.

## Configuration

Settings are resolved in this order, first match wins:

1. Command line parameters
2. Environment variables
3. `config.json` next to the script

Because the tool normally runs unattended at startup, `config.json` is the usual
choice. Copy the example and edit it:

```sh
cp config.example.json config.json
```

```json
{
  "ZoneId": "Z0123456789ABCDEFGHIJ",
  "RecordName": "host.example.com",
  "Ttl": 60
}
```

| Setting | Parameter (Windows) | Option (shell) | Environment variable | Default |
| --- | --- | --- | --- | --- |
| Hosted zone ID | `-ZoneId` | `--zone-id` | `ROUTE53_ZONE_ID` | *required* |
| Record name | `-RecordName` | `--record-name` | `ROUTE53_RECORD_NAME` | *required* |
| Record TTL | `-Ttl` | `--ttl` | `ROUTE53_TTL` | `60` |
| AWS CLI profile | `-AwsProfile` | `--profile` | `AWS_PROFILE` | none |

`config.json` is git-ignored, so your zone ID and host name stay out of the
repository.

## Usage

### Windows (startup)

1. Fill in `config.json`.
2. Press <kbd>Win</kbd>+<kbd>R</kbd>, run `shell:startup`.
3. Put a **shortcut** to `update-route53.cmd` in that folder.

Use a shortcut rather than moving the file — the launcher expects
`update-route53.ps1` and `config.json` to sit next to it.

The `.cmd` wrapper calls PowerShell with `-ExecutionPolicy Bypass` (Windows
blocks `.ps1` files by default) and appends all output to:

```
%LOCALAPPDATA%\aws-tools\update-route53.log
```

Check that log first if the record is not updating.

Run it by hand to test:

```bat
update-route53.cmd
update-route53.cmd -RecordName host.example.com -Ttl 300
```

If you need the record updated on a schedule rather than only at boot, register
the same `.cmd` as a Task Scheduler task — it is safe to run repeatedly, since
`UPSERT` is idempotent.

### macOS / Linux

```sh
./update-route53.sh
./update-route53.sh --zone-id Z0123456789ABCDEFGHIJ --record-name host.example.com
```

To run it at boot on Linux, wire it into a `systemd` unit with
`After=network-online.target`.

## IAM permissions

The instance role (or profile) needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"
    }
  ]
}
```

## Notes

- The instance must have a public IPv4 address; the tool fails with a clear
  error if metadata does not return one.
- The change batch is written to the system temp directory and deleted
  afterwards.

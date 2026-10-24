#!/usr/bin/env bash
#
# update-route53 - point a Route 53 A record at this EC2 instance's public IPv4.
#
# Settings are resolved in this order (first match wins):
#   1. Command line options  --zone-id, --record-name, --ttl, --profile
#   2. Environment variables ROUTE53_ZONE_ID, ROUTE53_RECORD_NAME, ROUTE53_TTL
#   3. config.json next to this script (see config.example.json)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMDS_BASE="http://169.254.169.254/latest"

ZONE_ID="${ROUTE53_ZONE_ID:-}"
RECORD_NAME="${ROUTE53_RECORD_NAME:-}"
TTL="${ROUTE53_TTL:-}"
AWS_CLI_PROFILE="${AWS_PROFILE:-}"

usage() {
    cat <<'EOF'
Usage: update-route53.sh [--zone-id ID] [--record-name NAME] [--ttl SECONDS] [--profile NAME]

Reads the public IPv4 address of the current EC2 instance from IMDSv2 and
UPSERTs it as an A record in the given Route 53 hosted zone.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --zone-id)     ZONE_ID="${2:?--zone-id needs a value}"; shift 2 ;;
        --record-name) RECORD_NAME="${2:?--record-name needs a value}"; shift 2 ;;
        --ttl)         TTL="${2:?--ttl needs a value}"; shift 2 ;;
        --profile)     AWS_CLI_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for cmd in aws curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd" >&2
        exit 1
    fi
done

CONFIG_FILE="$SCRIPT_DIR/config.json"
if [ -f "$CONFIG_FILE" ]; then
    [ -n "$ZONE_ID" ]     || ZONE_ID="$(jq -r '.ZoneId // empty' "$CONFIG_FILE")"
    [ -n "$RECORD_NAME" ] || RECORD_NAME="$(jq -r '.RecordName // empty' "$CONFIG_FILE")"
    [ -n "$TTL" ]         || TTL="$(jq -r '.Ttl // empty' "$CONFIG_FILE")"
    [ -n "$AWS_CLI_PROFILE" ] || AWS_CLI_PROFILE="$(jq -r '.AwsProfile // empty' "$CONFIG_FILE")"
fi

TTL="${TTL:-60}"

if [ -z "$ZONE_ID" ] || [ -z "$RECORD_NAME" ]; then
    echo "Missing zone id or record name. Use --zone-id/--record-name, the ROUTE53_* environment variables, or config.json." >&2
    exit 2
fi

echo "Resolving public IPv4 address from instance metadata..."
TOKEN="$(curl -fsS -m 5 -X PUT "$IMDS_BASE/api/token" \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
PUBLIC_IP="$(curl -fsS -m 5 "$IMDS_BASE/meta-data/public-ipv4" \
    -H "X-aws-ec2-metadata-token: $TOKEN")"

if ! printf '%s' "$PUBLIC_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    echo "Instance metadata returned an unexpected public IPv4 address: '$PUBLIC_IP'" >&2
    exit 1
fi

echo "Public IPv4 address: $PUBLIC_IP"
echo "Updating $RECORD_NAME (A, TTL $TTL) in hosted zone $ZONE_ID"

CHANGE_BATCH="$(jq -n \
    --arg name "$RECORD_NAME" \
    --arg ip "$PUBLIC_IP" \
    --argjson ttl "$TTL" \
    '{
        Comment: "Auto-update A record on instance startup",
        Changes: [{
            Action: "UPSERT",
            ResourceRecordSet: {
                Name: $name,
                Type: "A",
                TTL: $ttl,
                ResourceRecords: [{ Value: $ip }]
            }
        }]
    }')"

AWS_ARGS=(route53 change-resource-record-sets
    --hosted-zone-id "$ZONE_ID"
    --change-batch "$CHANGE_BATCH"
    --output json)
if [ -n "$AWS_CLI_PROFILE" ]; then
    AWS_ARGS+=(--profile "$AWS_CLI_PROFILE")
fi

aws "${AWS_ARGS[@]}" >/dev/null

echo "Done. $RECORD_NAME -> $PUBLIC_IP"

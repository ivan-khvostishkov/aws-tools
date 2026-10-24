#!/usr/bin/env bash
#
# open-aws-console - open the AWS Management Console in a browser using the
# credentials the AWS CLI is currently configured with (SSO, assumed role, or
# an EC2 instance role).
#
set -euo pipefail

IMDS_BASE="http://169.254.169.254/latest"
SIGNIN_URL="https://signin.aws.amazon.com/federation"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
AWS_CLI_PROFILE="${AWS_PROFILE:-}"
DESTINATION=""
PRINT_ONLY=0

usage() {
    cat <<'EOF'
Usage: open-aws-console.sh [--region REGION] [--profile NAME] [--destination URL] [--print]

  --region       Console region to land in (default: configured AWS region)
  --profile      AWS CLI profile to take credentials from
  --destination  Console page to open (default: the console home page)
  --print        Print the sign-in URL instead of opening a browser
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --region)      REGION="${2:?--region needs a value}"; shift 2 ;;
        --profile)     AWS_CLI_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
        --destination) DESTINATION="${2:?--destination needs a value}"; shift 2 ;;
        --print)       PRINT_ONLY=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd" >&2
        exit 1
    fi
done

if [ -n "$AWS_CLI_PROFILE" ]; then
    export AWS_PROFILE="$AWS_CLI_PROFILE"
fi

# Open a URL with whatever the platform provides.
open_url() {
    local url="$1"
    if command -v open >/dev/null 2>&1; then
        open "$url"            # macOS
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url"        # Linux desktop
    elif command -v wslview >/dev/null 2>&1; then
        wslview "$url"         # WSL
    else
        echo "No browser launcher found. Open this URL manually:" >&2
        printf '%s\n' "$url"
    fi
}

if curl -fsS -m 2 -X PUT "$IMDS_BASE/api/token" \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' >/dev/null 2>&1; then
    echo "Detected EC2 environment - using instance metadata for credentials"
    TOKEN="$(curl -fsS -m 5 -X PUT "$IMDS_BASE/api/token" \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')"
    ROLE_NAME="$(curl -fsS -m 5 "$IMDS_BASE/meta-data/iam/security-credentials/" \
        -H "X-aws-ec2-metadata-token: $TOKEN")"
    if [ -z "$ROLE_NAME" ]; then
        echo "No IAM role is attached to this instance, so there are no credentials to federate with." >&2
        exit 1
    fi
    CREDS="$(curl -fsS -m 5 "$IMDS_BASE/meta-data/iam/security-credentials/$ROLE_NAME" \
        -H "X-aws-ec2-metadata-token: $TOKEN")"
    ACCESS_KEY="$(printf '%s' "$CREDS" | jq -r '.AccessKeyId')"
    SECRET_KEY="$(printf '%s' "$CREDS" | jq -r '.SecretAccessKey')"
    SESSION_TOKEN="$(printf '%s' "$CREDS" | jq -r '.Token')"
else
    echo "Detected local environment - using AWS CLI credentials"
    if ! command -v aws >/dev/null 2>&1; then
        echo "AWS CLI not found on PATH. Install AWS CLI v2:" >&2
        echo "  https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
        exit 1
    fi
    if ! CREDS="$(aws configure export-credentials --format process 2>&1)"; then
        echo "Could not export AWS credentials. Run 'aws sso login' or check your profile." >&2
        printf '%s\n' "$CREDS" >&2
        exit 1
    fi
    ACCESS_KEY="$(printf '%s' "$CREDS" | jq -r '.AccessKeyId')"
    SECRET_KEY="$(printf '%s' "$CREDS" | jq -r '.SecretAccessKey')"
    SESSION_TOKEN="$(printf '%s' "$CREDS" | jq -r '.SessionToken // empty')"
fi

if [ -z "$SESSION_TOKEN" ] || [ "$SESSION_TOKEN" = "null" ]; then
    echo "Federated console sign-in needs temporary credentials (with a session token)." >&2
    echo "Use an SSO profile, an assumed role, or an instance role." >&2
    exit 1
fi

if [ -z "$REGION" ] && command -v aws >/dev/null 2>&1; then
    REGION="$(aws configure get region 2>/dev/null || true)"
fi
REGION="${REGION:-us-east-1}"
DESTINATION="${DESTINATION:-https://console.aws.amazon.com/console/home?region=$REGION}"

SESSION_DATA="$(jq -nc \
    --arg id "$ACCESS_KEY" \
    --arg key "$SECRET_KEY" \
    --arg token "$SESSION_TOKEN" \
    '{sessionId: $id, sessionKey: $key, sessionToken: $token}')"

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# SessionDuration is deliberately omitted: the federation endpoint rejects it when
# the session is built from temporary credentials, which is always the case here.
SIGNIN_TOKEN="$(curl -fsS "${SIGNIN_URL}?Action=getSigninToken&Session=$(urlencode "$SESSION_DATA")" \
    | jq -r '.SigninToken // empty')"

if [ -z "$SIGNIN_TOKEN" ]; then
    echo "The AWS federation endpoint did not return a sign-in token." >&2
    exit 1
fi

FEDERATED_URL="${SIGNIN_URL}?Action=login&Issuer=aws-tools&Destination=$(urlencode "$DESTINATION")&SigninToken=$(urlencode "$SIGNIN_TOKEN")"

if [ "$PRINT_ONLY" -eq 1 ]; then
    printf '%s\n' "$FEDERATED_URL"
else
    echo "Opening AWS Console for region $REGION..."
    open_url "$FEDERATED_URL"
fi

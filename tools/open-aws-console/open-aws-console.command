#!/usr/bin/env bash
#
# macOS double-click launcher. Finder only runs executables named *.command,
# so this is a thin wrapper around the portable shell script.
#
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
exec ./open-aws-console.sh "$@"

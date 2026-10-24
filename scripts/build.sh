#!/usr/bin/env bash
#
# Assemble the distributable tool tree into dist/.
#
# Each tool becomes a self-contained directory that can be copied anywhere and
# run in place. GitHub Actions uploads dist/ as a build artifact, which GitHub
# serves as a zip archive.
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
STAGE_DIR="$DIST_DIR/aws-tools"

TOOLS=(
    open-aws-console
    update-route53
)

echo "Cleaning $DIST_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"

for tool in "${TOOLS[@]}"; do
    src="$REPO_ROOT/tools/$tool"
    if [ ! -d "$src" ]; then
        echo "Tool directory not found: $src" >&2
        exit 1
    fi

    echo "Packaging $tool"
    cp -R "$src" "$STAGE_DIR/$tool"

    # The shipped tool reads config.json; only the example belongs in the build.
    rm -f "$STAGE_DIR/$tool/config.json"

    # Executable bits survive the zip on macOS/Linux; .cmd/.ps1 do not need them.
    find "$STAGE_DIR/$tool" -type f \( -name '*.sh' -o -name '*.command' \) -exec chmod 755 {} +
    find "$STAGE_DIR/$tool" -type f \( -name '*.ps1' -o -name '*.cmd' -o -name '*.json' -o -name '*.md' \) -exec chmod 644 {} +
done

cp "$REPO_ROOT/README.md" "$STAGE_DIR/README.md"

VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo 'unknown')"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
cat >"$STAGE_DIR/VERSION" <<EOF
version: $VERSION
commit:  $COMMIT
built:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

echo
echo "Build complete:"
find "$STAGE_DIR" -type f | sed "s|$DIST_DIR/|  |" | sort

#!/bin/bash
# InjectVersion — reads version from Library/Version.swift and writes it into
# GUI/App/Info.plist so that the GUI bundle always reflects the single source
# of truth.
#
# Usage:
#   Scripts/inject_version.sh          # auto-detect version + build number
#   TS_BUILD_NUMBER=42 Scripts/inject_version.sh   # override build number
#
# This script is idempotent — safe to run multiple times.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
VERSION_FILE="$REPO_ROOT/Library/Version.swift"
PLIST_FILE="$REPO_ROOT/GUI/App/Info.plist"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "error: Version.swift not found at $VERSION_FILE" >&2
    exit 1
fi
if [[ ! -f "$PLIST_FILE" ]]; then
    echo "error: Info.plist not found at $PLIST_FILE" >&2
    exit 1
fi

# Extract currentVersion from Version.swift (e.g. 1.0.0)
SEMVER=$(grep "currentVersion\s*=" "$VERSION_FILE" | sed 's/.*"\([^"]*\)".*/\1/')
if [[ -z "$SEMVER" ]]; then
    echo "error: could not parse currentVersion from $VERSION_FILE" >&2
    exit 1
fi

# Build number: use TS_BUILD_NUMBER env if set, otherwise git commit count
if [[ -n "${TS_BUILD_NUMBER:-}" ]]; then
    BUILD_NUM="$TS_BUILD_NUMBER"
else
    BUILD_NUM=$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo "1")
fi

PLIST_BUDDY="/usr/libexec/PlistBuddy"

"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $SEMVER" "$PLIST_FILE"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUM" "$PLIST_FILE"

echo "Version injected → CFBundleShortVersionString=$SEMVER, CFBundleVersion=$BUILD_NUM"

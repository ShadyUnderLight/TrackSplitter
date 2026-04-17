#!/bin/bash
# inject_version.sh — Generates Library/Version.swift from Version.swift.in and
# injects version into GUI/App/Info.plist.
#
# Run before building on all platforms (local dev, CI, release).
# Idempotent — safe to run multiple times.
#
# Usage:
#   ./Scripts/inject_version.sh               # auto-detect build number + SHA
#   TS_BUILD_NUMBER=42 ./Scripts/inject_version.sh  # override build number
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TEMPLATE="$REPO_ROOT/Library/Version.swift.in"
OUTPUT="$REPO_ROOT/Library/Version.swift"
PLIST="$REPO_ROOT/GUI/App/Info.plist"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "error: Version.swift.in not found at $TEMPLATE" >&2
    exit 1
fi

# --- Extract values ---
# currentVersion is a plain string in the template (e.g. "1.0.0") — read it directly.
SEMVER=$(grep "currentVersion\s*=" "$TEMPLATE" | sed 's/.*"\([^"]*\)".*/\1/')
if [[ -z "$SEMVER" ]]; then
    echo "error: could not parse currentVersion from $TEMPLATE" >&2
    exit 1
fi

# Build number: TS_BUILD_NUMBER env or git commit count
if [[ -n "${TS_BUILD_NUMBER:-}" ]]; then
    BUILD_NUM="$TS_BUILD_NUMBER"
else
    BUILD_NUM=$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo "1")
fi

SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# --- Generate Library/Version.swift ---
sed \
    -e "s/@BUILD@/$BUILD_NUM/g" \
    -e "s/@SHA@/$SHA/g" \
    "$TEMPLATE" > "$OUTPUT"

# --- Inject into GUI Info.plist ---
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SEMVER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$PLIST"

echo "Version injected → semver=$SEMVER, build=$BUILD_NUM, sha=$SHA"
echo "  • Library/Version.swift  (generated from Version.swift.in)"
echo "  • GUI/App/Info.plist     CFBundleShortVersionString=$SEMVER CFBundleVersion=$BUILD_NUM"

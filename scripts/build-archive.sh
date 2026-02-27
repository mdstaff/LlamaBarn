#!/usr/bin/env bash
# build-archive.sh — Build and export a local Release .app of LlamaBarn using xcodebuild CLI
#
# Usage:
#   ./scripts/build-archive.sh [version]
#
# Examples:
#   ./scripts/build-archive.sh           # version defaults to 0.0.0 (as set in project)
#   ./scripts/build-archive.sh 1.0.0     # sets MARKETING_VERSION to 1.0.0
#   ./scripts/build-archive.sh 1.2.3-dev # fine for local builds; use semver for releases
#
# Output:
#   build/export/LlamaBarn.app           # ready to copy to /Applications

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/LlamaBarn.xcodeproj"
SCHEME="LlamaBarn"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"  # auto build number, override via env
VERSION="${1:-}"                                        # optional first arg sets marketing version
ARCHIVE_DIR="$REPO_ROOT/build/archives"
ARCHIVE_PATH="$ARCHIVE_DIR/LlamaBarn.xcarchive"
EXPORT_DIR="$REPO_ROOT/build/export"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/build.log"

# Optional: pipe through xcbeautify if installed for cleaner output
if command -v xcbeautify &>/dev/null; then
  FORMATTER="xcbeautify"
else
  FORMATTER="cat"
fi

mkdir -p "$LOG_DIR"
# Tee all output (stdout + stderr) to build.log while still printing to terminal
exec > >(tee "$LOG_FILE") 2>&1

echo "▶ LlamaBarn — archive + export"
echo "  Project      : $PROJECT"
echo "  Scheme       : $SCHEME"
echo "  Build number : $BUILD_NUMBER"
[[ -n "$VERSION" ]] && echo "  Version      : $VERSION" || echo "  Version      : (project default — 0.0.0)"
echo "  Archive      : $ARCHIVE_PATH"
echo "  Export       : $EXPORT_DIR/LlamaBarn.app"
echo "  Log          : $LOG_FILE"
echo ""

mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

# Build version override args (only set when a version was provided)
VERSION_ARGS=()
if [[ -n "$VERSION" ]]; then
  VERSION_ARGS=(
    MARKETING_VERSION="$VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  )
fi

# --- Archive ---
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
  | $FORMATTER

echo ""
echo "✓ Archive: $ARCHIVE_PATH"

# --- Extract .app directly from archive (no signing team required) ---
# xcodebuild -exportArchive requires a provisioning team even for local builds in Xcode 15+.
# Copying from the archive's Products folder is the unsigned equivalent of Xcode's "Copy App".
echo "▶ Copying .app from archive..."
rm -rf "$EXPORT_DIR/LlamaBarn.app"
cp -R "$ARCHIVE_PATH/Products/Applications/LlamaBarn.app" "$EXPORT_DIR/LlamaBarn.app"

echo ""
echo "✓ Export complete: $EXPORT_DIR/LlamaBarn.app"
echo ""
echo "To install:"
echo "  cp -R \"$EXPORT_DIR/LlamaBarn.app\" /Applications/"
echo "  open /Applications/LlamaBarn.app"

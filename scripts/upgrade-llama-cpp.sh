#!/usr/bin/env bash
# upgrade-llama-cpp.sh — Download and install a new llama.cpp release into llama-cpp/
#
# Usage:
#   ./scripts/upgrade-llama-cpp.sh <tag>
#   ./scripts/upgrade-llama-cpp.sh --check <tag>   # verify asset exists, do not install
#
# Examples:
#   ./scripts/upgrade-llama-cpp.sh b8416
#   ./scripts/upgrade-llama-cpp.sh --check b8416
#
# What it does:
#   1. Verifies the macOS arm64 asset exists on ggml-org/llama.cpp releases
#   2. Downloads llama-{tag}-bin-macos-arm64.tar.gz
#   3. Extracts it to a temp dir
#   4. Copies real files only (resolves symlinks) — renames *.0.9.x.dylib → *.0.dylib
#   5. Replaces llama-cpp/ contents in the repo
#   6. Writes version.txt
#   7. Validates codesign and dylib linkage on the installed binary
#
# Requirements:
#   - gh CLI (brew install gh) authenticated
#   - macOS with codesign and otool

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_CPP_DIR="$REPO_ROOT/llama-cpp"

# --- Parse args ---
CHECK_ONLY=false
TAG=""

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    *) TAG="$arg" ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: tag required" >&2
  echo "usage: $0 [--check] <tag>   (e.g. $0 b8416)" >&2
  exit 1
fi

ASSET="llama-${TAG}-bin-macos-arm64.tar.gz"

# --- Verify asset exists on GitHub before touching anything ---
echo "▶ Verifying $ASSET exists on ggml-org/llama.cpp@$TAG..."
ASSET_SIZE="$(gh release view "$TAG" \
  --repo ggml-org/llama.cpp \
  --json assets \
  --jq ".assets[] | select(.name == \"$ASSET\") | .size" 2>/dev/null || true)"

if [[ -z "$ASSET_SIZE" ]]; then
  echo "error: asset '$ASSET' not found in release $TAG on ggml-org/llama.cpp" >&2
  echo "  Check available assets with: gh release view $TAG --repo ggml-org/llama.cpp" >&2
  exit 1
fi
echo "✓ Asset found ($(( ASSET_SIZE / 1024 / 1024 )) MB)"

if [[ "$CHECK_ONLY" == true ]]; then
  echo ""
  echo "✓ Check passed — $ASSET exists. Run without --check to install."
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo ""
echo "▶ Upgrading llama-cpp to $TAG"
echo "  Repo       : $REPO_ROOT"
echo "  llama-cpp/ : $LLAMA_CPP_DIR"
echo "  Asset      : $ASSET"
echo "  Work dir   : $WORK_DIR"
echo ""

# --- Download ---
echo "▶ Downloading $ASSET from ggml-org/llama.cpp@$TAG..."
gh release download "$TAG" \
  --repo ggml-org/llama.cpp \
  --pattern "$ASSET" \
  --dir "$WORK_DIR"
echo "✓ Downloaded"

# --- Extract ---
echo "▶ Extracting..."
tar xzf "$WORK_DIR/$ASSET" -C "$WORK_DIR"
# The tarball extracts to a directory named llama-{TAG}
EXTRACT_DIR="$WORK_DIR/llama-${TAG}"
if [[ ! -d "$EXTRACT_DIR" ]]; then
  echo "error: expected extract dir $EXTRACT_DIR not found" >&2
  ls "$WORK_DIR" >&2
  exit 1
fi
echo "✓ Extracted to $EXTRACT_DIR"

# --- Stage only what LlamaBarn needs: llama-server + its @rpath dylib dependencies ---
# The release tarball also contains 20+ CLI binaries (llama-cli, llama-bench, etc.)
# and LICENSE — we explicitly ignore all of that.
#
# Rather than hardcoding a glob pattern (e.g. *.0.dylib), we ask llama-server itself
# what it links against via otool -L. This stays correct even if naming changes (e.g. *.1.dylib).
echo "▶ Staging llama-server and its dylib dependencies (ignoring other CLI binaries)..."

STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$STAGE_DIR"

# Copy llama-server (always a real file in the tarball)
if [[ ! -f "$EXTRACT_DIR/llama-server" ]]; then
  echo "error: llama-server not found in extract dir" >&2
  exit 1
fi
cp "$EXTRACT_DIR/llama-server" "$STAGE_DIR/llama-server"
chmod +x "$STAGE_DIR/llama-server"
echo "  llama-server"

# Discover required dylibs from llama-server's load commands
# otool -L prints lines like:  @rpath/libggml-cpu.0.dylib (compatibility ...)
# We extract just the filename portion after @rpath/
REQUIRED_DYLIBS=()
while IFS= read -r dep_name; do
  REQUIRED_DYLIBS+=("$dep_name")
done < <(otool -L "$EXTRACT_DIR/llama-server" | grep '@rpath/' | awk '{print $1}' | sed 's|@rpath/||')

if [[ ${#REQUIRED_DYLIBS[@]} -eq 0 ]]; then
  echo "error: otool found no @rpath dylib dependencies in llama-server" >&2
  exit 1
fi

# For each required dylib, find and copy it from the extract dir.
# The file may be a symlink — resolve it so we copy the real content,
# but always write it under the name llama-server expects (e.g. libggml-cpu.0.dylib).
for dep_name in "${REQUIRED_DYLIBS[@]}"; do
  src="$EXTRACT_DIR/$dep_name"
  if [[ ! -e "$src" ]]; then
    echo "error: required dylib '$dep_name' not found in extract dir" >&2
    ls "$EXTRACT_DIR"/*.dylib >&2
    exit 1
  fi
  # Resolve symlink chain to the real file
  real_src="$(cd "$EXTRACT_DIR" && python3 -c "import os; print(os.path.realpath('$dep_name'))")"
  cp "$real_src" "$STAGE_DIR/$dep_name"
  echo "  $dep_name"
done

STAGED_COUNT="$(ls "$STAGE_DIR" | wc -l | tr -d ' ')"
echo "✓ Staged $STAGED_COUNT files (1 binary + $((STAGED_COUNT - 1)) dylibs)"

# --- Validate staged binary before touching the repo ---
echo ""
echo "▶ Validating staged binary..."

STAGED_SERVER="$STAGE_DIR/llama-server"

# codesign check
CODESIGN_OUT="$(codesign -dv "$STAGED_SERVER" 2>&1)"
echo "$CODESIGN_OUT" | grep -E "^(Signature|Identifier|Format)" | sed 's/^/  /'

if echo "$CODESIGN_OUT" | grep -q "adhoc"; then
  echo "  ✓ Signature: adhoc (expected)"
else
  echo "  ✗ Unexpected signature — aborting" >&2
  echo "$CODESIGN_OUT" >&2
  exit 1
fi

# otool rpath check — must use @loader_path
RPATH="$(otool -l "$STAGED_SERVER" | grep -A2 LC_RPATH | grep path | awk '{print $2}')"
if [[ "$RPATH" == "@loader_path" ]]; then
  echo "  ✓ rpath: @loader_path (expected)"
else
  echo "  ✗ Unexpected rpath '$RPATH' — aborting" >&2
  exit 1
fi

# Verify all @rpath dylibs are present in stage (sanity check — staging should have caught this)
MISSING=0
while IFS= read -r dep_name; do
  if [[ ! -f "$STAGE_DIR/$dep_name" ]]; then
    echo "  ✗ Missing staged dylib: $dep_name" >&2
    MISSING=$((MISSING + 1))
  fi
done < <(otool -L "$STAGED_SERVER" | grep '@rpath/' | awk '{print $1}' | sed 's|@rpath/||')

if [[ $MISSING -gt 0 ]]; then
  echo "error: $MISSING missing dylib(s) in stage — aborting" >&2
  exit 1
fi
echo "  ✓ All dylib dependencies present"

echo "✓ Validation passed"

# --- Show current version before replacing ---
CURRENT_VERSION="$(cat "$LLAMA_CPP_DIR/version.txt" 2>/dev/null || echo "(none)")"
echo ""
echo "▶ Installing (replacing $CURRENT_VERSION → $TAG)..."

# Remove old files, copy new ones
rm -f "$LLAMA_CPP_DIR"/llama-server "$LLAMA_CPP_DIR"/*.dylib

cp "$STAGE_DIR"/llama-server "$LLAMA_CPP_DIR/llama-server"
chmod +x "$LLAMA_CPP_DIR/llama-server"

for dylib in "$STAGE_DIR"/*.dylib; do
  cp "$dylib" "$LLAMA_CPP_DIR/$(basename "$dylib")"
done

# Write version
echo "$TAG" > "$LLAMA_CPP_DIR/version.txt"

echo "✓ Installed"

# --- Final check on installed files ---
echo ""
echo "▶ Installed files:"
ls -lh "$LLAMA_CPP_DIR"

echo ""
echo "✓ llama-cpp upgraded: $CURRENT_VERSION → $TAG"
echo ""
echo "Next steps:"
echo "  1. Run ./scripts/build-archive.sh to build the app"
echo "  2. Test: open build/export/LlamaBarn.app"
echo "  3. git add llama-cpp/ && git commit -m 'Update llama.cpp to $TAG'"

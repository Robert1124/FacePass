#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FacePass"
APP_VERSION="${FACEPASS_APP_VERSION:-0.1.5}"
APP_DIR="${FACEPASS_APP_DIR:-$ROOT_DIR/dist/$APP_NAME.app}"
OUTPUT_DIR="$ROOT_DIR/dist/release"
ALLOW_AD_HOC="false"

usage() {
  cat <<'USAGE'
Usage: script/package_release.sh [--allow-ad-hoc] [--help]

Package an already staged FacePass.app into a Sparkle/GitHub Release DMG.

Options:
  --allow-ad-hoc  Permit ad-hoc signatures for local dry-run packaging only.
  --help          Show this help text.

Environment:
  FACEPASS_APP_VERSION  Defaults to 0.1.5 and controls the DMG filename.
  FACEPASS_APP_DIR      Optional path to an already staged FacePass.app bundle.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-ad-hoc)
      ALLOW_AD_HOC="true"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

require_bundle_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_DIR/Contents/Info.plist")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Info.plist $key mismatch: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

require_release_signature() {
  local codesign_info spctl_output
  codesign_info="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
  if grep -q '^Signature=adhoc$' <<< "$codesign_info"; then
    echo "Release packaging requires a Developer ID Application signature. Use --allow-ad-hoc only for local dry runs." >&2
    exit 1
  fi

  if grep -q '^Authority=Developer ID Application:' <<< "$codesign_info"; then
    return
  fi

  if spctl_output="$(spctl --assess --type execute --verbose=4 "$APP_DIR" 2>&1)"; then
    if grep -Eq 'source=(Notarized )?Developer ID' <<< "$spctl_output"; then
      return
    fi
  fi

  echo "Release packaging requires a Developer ID Application signature. Use --allow-ad-hoc only for local dry runs." >&2
  exit 1
}

require_entitlement_true() {
  local bundle_path="$1"
  local entitlement_key="$2"
  local entitlements_plist

  entitlements_plist="$(mktemp "${TMPDIR:-/tmp}/facepass-entitlements.XXXXXX")"
  if ! codesign -d --entitlements :- "$bundle_path" >"$entitlements_plist" 2>/dev/null; then
    rm -f "$entitlements_plist"
    echo "Could not inspect code signing entitlements for $bundle_path." >&2
    exit 1
  fi

  local actual_value
  actual_value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement_key" "$entitlements_plist" 2>/dev/null || true)"
  rm -f "$entitlements_plist"

  if [[ "$actual_value" != "true" ]]; then
    echo "$bundle_path is missing required entitlement: $entitlement_key=true" >&2
    exit 1
  fi
}

if [[ ! -d "$APP_DIR" ]]; then
  echo "Staged app not found at $APP_DIR" >&2
  exit 1
fi

if [[ ! -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "Sparkle.framework missing from $APP_DIR" >&2
  exit 1
fi

if ! otool -l "$APP_DIR/Contents/MacOS/$APP_NAME" | grep -Fq 'path @executable_path/../Frameworks '; then
  echo "App executable is missing @executable_path/../Frameworks runtime search path for bundled frameworks." >&2
  exit 1
fi

require_bundle_value "SUFeedURL" "https://facepass.robertw.me/updates/appcast.xml"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_DIR/Contents/Info.plist" >/dev/null

codesign --verify --strict --deep "$APP_DIR"
require_entitlement_true "$APP_DIR" "com.apple.security.device.camera"

if [[ "$ALLOW_AD_HOC" != "true" ]]; then
  require_release_signature
fi

mkdir -p "$OUTPUT_DIR"
PACKAGE_PATH="$OUTPUT_DIR/$APP_NAME-$APP_VERSION.dmg"
VOLUME_NAME="$APP_NAME $APP_VERSION"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/facepass-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

rm -f "$PACKAGE_PATH" "$PACKAGE_PATH.sha256"
/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$PACKAGE_PATH"

if command -v hdiutil >/dev/null 2>&1; then
  hdiutil verify "$PACKAGE_PATH"
fi

shasum -a 256 "$PACKAGE_PATH" > "$PACKAGE_PATH.sha256"

echo "Packaged $PACKAGE_PATH"
echo "Wrote checksum $PACKAGE_PATH.sha256"

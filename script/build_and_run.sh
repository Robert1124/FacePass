#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="debug"
MODE="run"
APP_NAME="FacePass"
APP_VERSION="${FACEPASS_APP_VERSION:-0.1.0}"
BUNDLE_VERSION="${FACEPASS_BUNDLE_VERSION:-1}"
SPARKLE_FEED_URL="https://facepass.app/updates/appcast.xml"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CACHE_APP_DIR="${HOME}/Library/Caches/FacePass/dist/$APP_NAME.app"
LEGACY_APP_PAYLOAD_DIR="$ROOT_DIR/dist/.$APP_NAME.bundle"
LOCAL_DRY_RUN_OUTPUT_DIR="$ROOT_DIR/dist/local-release-dry-run"
LOCAL_DRY_RUN_PACKAGE_PATH="$LOCAL_DRY_RUN_OUTPUT_DIR/$APP_NAME-$APP_VERSION.dry-run.zip"
APP_ICON="$ROOT_DIR/Resources/FacePass.icns"
MODEL_REVISION="af6d057c9b0ec4071d4c49c80e3539258798b609"
BUNDLED_MODEL_SOURCE="$ROOT_DIR/Artifacts/Phase8/AuraFace-v1/$MODEL_REVISION/coreml-legacy/glintr100-legacy.mlmodel"
BUNDLED_MODEL_SHA256="8e3204d64aad48970c91be2b697d9fb1e88611eded49d5adc49c1fe9453bb3d9"
BUNDLED_MODEL_SIZE="260665538"
BUNDLED_MODEL_RESOURCE_DIR="Contents/Resources/Models/AuraFace-v1/$MODEL_REVISION"
BUNDLED_MODEL_COMPILED_NAME="glintr100-legacy.mlmodelc"
STAGING_PARENT=""
STRICT_VERIFIED_APP_DIR=""

cleanup_staging() {
  if [[ -n "$STAGING_PARENT" ]]; then
    rm -rf "$STAGING_PARENT"
  fi
}

trap cleanup_staging EXIT

clean_xattrs() {
  local path="$1"
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$path"
    xattr -dr com.apple.FinderInfo "$path" 2>/dev/null || true
    xattr -dr com.apple.ResourceFork "$path" 2>/dev/null || true
  fi
}

clean_app_xattrs() {
  clean_xattrs "$APP_DIR"
}

verify_strict_codesign() {
  local path="$1"
  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --strict --deep "$path"
  fi
}

sign_ad_hoc() {
  local path="$1"
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$path" >/dev/null
  fi
}

verify_physical_app_bundle() {
  local path="$1"

  if [[ -L "$path" ]]; then
    echo "$path must be a physical app bundle, not a symlink" >&2
    exit 1
  fi

  if [[ ! -d "$path" ]]; then
    echo "App bundle not found at $path" >&2
    exit 1
  fi

  if [[ ! -x "$path/Contents/MacOS/$APP_NAME" ]]; then
    echo "App executable missing or not executable at $path/Contents/MacOS/$APP_NAME" >&2
    exit 1
  fi

  if [[ ! -f "$path/Contents/Resources/FacePass.icns" ]]; then
    echo "App icon missing at $path/Contents/Resources/FacePass.icns" >&2
    exit 1
  fi

  if [[ ! -d "$path/$BUNDLED_MODEL_RESOURCE_DIR/$BUNDLED_MODEL_COMPILED_NAME" ]]; then
    echo "Compiled bundled model missing at $path/$BUNDLED_MODEL_RESOURCE_DIR/$BUNDLED_MODEL_COMPILED_NAME" >&2
    exit 1
  fi

  if [[ ! -d "$path/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "Sparkle framework missing at $path/Contents/Frameworks/Sparkle.framework" >&2
    exit 1
  fi

  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$path/Contents/Info.plist")" == "FacePass" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$path/Contents/Info.plist")" == "$SPARKLE_FEED_URL" ]]
}

publish_physical_app() {
  local source_path="$1"
  local destination_path="$2"

  if [[ -L "$destination_path" ]]; then
    rm -f "$destination_path"
  else
    rm -rf "$destination_path"
  fi

  mkdir -p "$(dirname "$destination_path")"
  /usr/bin/ditto --norsrc "$source_path" "$destination_path"
  clean_xattrs "$destination_path"
  verify_physical_app_bundle "$destination_path"
}

file_size_bytes() {
  stat -f '%z' "$1"
}

verify_bundled_model_source() {
  if [[ ! -f "$BUNDLED_MODEL_SOURCE" ]]; then
    echo "Bundled model source not found at $BUNDLED_MODEL_SOURCE" >&2
    exit 1
  fi

  local actual_size
  actual_size="$(file_size_bytes "$BUNDLED_MODEL_SOURCE")"
  if [[ "$actual_size" != "$BUNDLED_MODEL_SIZE" ]]; then
    echo "Bundled model source size mismatch: expected $BUNDLED_MODEL_SIZE, got $actual_size" >&2
    exit 1
  fi

  local actual_sha256
  actual_sha256="$(shasum -a 256 "$BUNDLED_MODEL_SOURCE" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$BUNDLED_MODEL_SHA256" ]]; then
    echo "Bundled model source checksum mismatch: expected $BUNDLED_MODEL_SHA256, got $actual_sha256" >&2
    exit 1
  fi
}

stage_bundled_model() {
  verify_bundled_model_source

  if ! xcrun --find coremlcompiler >/dev/null 2>&1; then
    echo "coremlcompiler not found through xcrun" >&2
    exit 1
  fi

  local model_resource_dir="$STAGED_APP_DIR/$BUNDLED_MODEL_RESOURCE_DIR"
  mkdir -p "$model_resource_dir"
  xcrun coremlcompiler compile "$BUNDLED_MODEL_SOURCE" "$model_resource_dir" >/dev/null

  if [[ ! -d "$model_resource_dir/$BUNDLED_MODEL_COMPILED_NAME" ]]; then
    echo "Compiled bundled model not found at $model_resource_dir/$BUNDLED_MODEL_COMPILED_NAME" >&2
    exit 1
  fi
}

stage_sparkle_framework() {
  local framework_path=""

  framework_path="$(find "$BIN_DIR" -name Sparkle.framework -type d -print -quit 2>/dev/null || true)"
  if [[ -z "$framework_path" ]]; then
    framework_path="$(find "$ROOT_DIR/.build/artifacts" -path '*macos*Sparkle.framework' -type d -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$framework_path" ]]; then
    framework_path="$(find "$ROOT_DIR/.build" -name Sparkle.framework -type d -print -quit 2>/dev/null || true)"
  fi

  if [[ -z "$framework_path" ]]; then
    echo "Sparkle.framework was not found in the SwiftPM build artifacts" >&2
    exit 1
  fi

  mkdir -p "$STAGED_APP_DIR/Contents/Frameworks"
  /usr/bin/ditto --norsrc "$framework_path" "$STAGED_APP_DIR/Contents/Frameworks/Sparkle.framework"
  clean_xattrs "$STAGED_APP_DIR/Contents/Frameworks/Sparkle.framework"
  sign_ad_hoc "$STAGED_APP_DIR/Contents/Frameworks/Sparkle.framework"
}

require_sparkle_public_key() {
  if [[ -z "${FACEPASS_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    cat >&2 <<'EOF'
FACEPASS_SPARKLE_PUBLIC_ED_KEY is required for release packaging.
Do not commit Sparkle signing keys. Provide the public EdDSA key through the
release environment, and keep the private key only in the signing environment.
EOF
    exit 1
  fi
}

package_local_dry_run_archive() {
  mkdir -p "$LOCAL_DRY_RUN_OUTPUT_DIR"
  rm -f "$LOCAL_DRY_RUN_PACKAGE_PATH"
  /usr/bin/ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 "$APP_DIR" "$LOCAL_DRY_RUN_PACKAGE_PATH"
  echo "Packaged local dry-run archive: $LOCAL_DRY_RUN_PACKAGE_PATH"
  echo "This archive is not a public release artifact. Formal releases use Developer ID signing, notarization, and script/package_release.sh."
}

publish_app() {
  rm -rf "$LEGACY_APP_PAYLOAD_DIR"
  publish_physical_app "$STAGED_APP_DIR" "$APP_DIR"

  if verify_strict_codesign "$APP_DIR" >/dev/null 2>&1; then
    STRICT_VERIFIED_APP_DIR="$APP_DIR"
    echo "Strict codesign verification passed for $APP_DIR"
    return
  fi

  cat >&2 <<EOF
Warning: $APP_DIR is a physical app bundle, but strict codesign verification failed after publishing.
This can happen in FileProvider or iCloud-backed folders when Finder metadata is added after copy.
Publishing a physical fallback bundle for strict verification at:
  $CACHE_APP_DIR
EOF

  publish_physical_app "$STAGED_APP_DIR" "$CACHE_APP_DIR"
  sign_ad_hoc "$CACHE_APP_DIR"
  verify_strict_codesign "$CACHE_APP_DIR"
  STRICT_VERIFIED_APP_DIR="$CACHE_APP_DIR"

  cat >&2 <<EOF
Strict codesign verification passed for fallback app:
  $CACHE_APP_DIR
Use the fallback app if strict verification matters. No symlink was created at $APP_DIR.
EOF
}

usage() {
  cat <<'USAGE'
Usage: script/build_and_run.sh [--debug] [--release] [--verify] [--package-dry-run] [--logs] [--telemetry] [--help]

Modes:
  --debug      Build the debug executable, stage dist/FacePass.app, and launch it.
  --release    Build release configuration, stage dist/FacePass.app, and verify without launching.
               This is still a local ad-hoc-signed app until the GitHub release workflow
               applies Developer ID signing and notarization.
  --verify     Build and stage the app, then verify bundle shape and Info.plist.
  --package-dry-run
               Build release configuration, stage and verify dist/FacePass.app, then create a local-only
               ad-hoc-signed dist/local-release-dry-run/FacePass-$FACEPASS_APP_VERSION.dry-run.zip archive.
  --logs       Build, launch, then stream unified logs for the FacePass process.
  --telemetry  Report telemetry status. FacePass Phase 1 intentionally has none.
  --help       Show this help text.

Release environment:
  FACEPASS_APP_VERSION              Defaults to 0.1.0.
  FACEPASS_BUNDLE_VERSION           Defaults to 1.
  FACEPASS_SPARKLE_PUBLIC_ED_KEY    Required for --package-dry-run; optional for local debug/verify.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION="debug"
      MODE="run"
      ;;
    --release)
      CONFIGURATION="release"
      MODE="verify"
      ;;
    --verify)
      CONFIGURATION="debug"
      MODE="verify"
      ;;
    --package)
      echo "--package was renamed to --package-dry-run because local archives are not public release artifacts." >&2
      echo "Use script/package_release.sh after Developer ID signing and notarization in the release workflow." >&2
      exit 64
      ;;
    --package-dry-run)
      CONFIGURATION="release"
      MODE="package-dry-run"
      ;;
    --logs)
      CONFIGURATION="debug"
      MODE="logs"
      ;;
    --telemetry)
      MODE="telemetry"
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

if [[ "$MODE" == "telemetry" ]]; then
  echo "FacePass Phase 1 does not include telemetry, analytics, sync, or network behavior."
  exit 0
fi

cd "$ROOT_DIR"

if [[ "$MODE" == "package-dry-run" ]]; then
  require_sparkle_public_key
fi

if [[ "$CONFIGURATION" == "release" ]]; then
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
else
  swift build
  BIN_DIR="$(swift build --show-bin-path)"
fi
BINARY_PATH="$BIN_DIR/$APP_NAME"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Built executable not found at $BINARY_PATH" >&2
  exit 1
fi

if [[ ! -f "$APP_ICON" ]]; then
  echo "App icon not found at $APP_ICON" >&2
  exit 1
fi

STAGING_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/facepass-build.XXXXXX")"
STAGED_APP_DIR="$STAGING_PARENT/$APP_NAME.app"

mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"

cp "$BINARY_PATH" "$STAGED_APP_DIR/Contents/MacOS/$APP_NAME"
cp "$APP_ICON" "$STAGED_APP_DIR/Contents/Resources/FacePass.icns"
stage_sparkle_framework

cat > "$STAGED_APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>FacePass</string>
  <key>CFBundleIdentifier</key>
  <string>dev.facepass.FacePass</string>
  <key>CFBundleIconFile</key>
  <string>FacePass</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>FacePass</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSBonjourServices</key>
  <array>
    <string>_facepass._tcp</string>
  </array>
  <key>NSCameraUsageDescription</key>
  <string>FacePass uses the camera only for short local recognition, enrollment, and opt-in wake-triggered lock-screen checks. It does not keep the camera running or persist raw frames or photos.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>FacePass publishes a local Bonjour service and accepts signed iPhone StandBy Unlock pairing and unlock requests on your local network.</string>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$STAGED_APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$STAGED_APP_DIR/Contents/Info.plist"
if [[ -n "${FACEPASS_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $FACEPASS_SPARKLE_PUBLIC_ED_KEY" "$STAGED_APP_DIR/Contents/Info.plist"
fi

plutil -lint "$STAGED_APP_DIR/Contents/Info.plist"

stage_bundled_model

clean_xattrs "$STAGED_APP_DIR"

sign_ad_hoc "$STAGED_APP_DIR"
verify_strict_codesign "$STAGED_APP_DIR" >/dev/null

publish_app

if [[ "$MODE" == "verify" || "$MODE" == "package-dry-run" ]]; then
  clean_app_xattrs
  verify_physical_app_bundle "$APP_DIR"
  if [[ "$STRICT_VERIFIED_APP_DIR" == "$APP_DIR" ]]; then
    echo "Verified physical dist app with strict codesign: $APP_DIR"
  else
    verify_physical_app_bundle "$CACHE_APP_DIR"
    echo "Verified physical dist app bundle shape: $APP_DIR"
    echo "Verified strict codesign fallback app: $CACHE_APP_DIR"
  fi
  if [[ "$MODE" == "package-dry-run" ]]; then
    /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_DIR/Contents/Info.plist" >/dev/null
    package_local_dry_run_archive
  fi
  exit 0
fi

/usr/bin/open -n "$APP_DIR"
echo "Launched $APP_DIR"

if [[ "$MODE" == "logs" ]]; then
  log stream --style compact --predicate 'process == "FacePass"'
fi

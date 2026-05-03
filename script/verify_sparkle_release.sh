#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_FEED_URL="https://facepass.app/updates/appcast.xml"
APP_BUNDLE_PATH=""
RELEASE_PACKAGE_PATH=""
REQUIRE_APP="false"
EXPECT_WORKFLOW="false"
EXPECT_APPCAST="false"
REQUIRE_SIGNED_APPCAST_ITEM="false"

usage() {
  cat <<'USAGE'
Usage: script/verify_sparkle_release.sh [--app /path/to/FacePass.app] [--require-app] [--expect-workflow] [--expect-appcast] [--strict] [--release-package /path/to/FacePass.dmg]

Validates local Sparkle release/update wiring without using signing credentials,
private keys, real passwords, network access, telemetry, or profiling.

Checks:
  - Sparkle dependency and updater integration markers exist in source.
  - Generated/built app Info.plist contains the expected SUFeedURL.
  - Generated/built app Info.plist contains a non-placeholder SUPublicEDKey.
  - Release workflow, when present, is valid YAML and tag-triggered.
  - Release workflow uses DMG final artifacts for GitHub Release upload, Sparkle appcast input, and release verification.
  - Appcast, when present, is valid XML and points DMG packages to GitHub Releases.

Strict gate options:
  --require-app       Fail unless --app points at a staged app bundle.
  --expect-workflow   Fail unless .github/workflows/release.yml exists and passes checks.
  --expect-appcast    Fail unless website/updates/appcast.xml exists and passes checks.
  --strict            Enable all strict presence gate options.
  --release-package   Require a real signed appcast item for the given release package.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

note() {
  echo "note: $*"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "Missing required file: $path"
}

validate_xml() {
  local path="$1"
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$path"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -rrexml/document -e 'REXML::Document.new(File.read(ARGV.fetch(0)))' "$path"
  else
    fail "Neither xmllint nor ruby is available for XML validation."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || fail "--app requires a path"
      APP_BUNDLE_PATH="$2"
      shift 2
      ;;
    --require-app)
      REQUIRE_APP="true"
      shift
      ;;
    --expect-workflow)
      EXPECT_WORKFLOW="true"
      shift
      ;;
    --expect-appcast)
      EXPECT_APPCAST="true"
      shift
      ;;
    --strict)
      REQUIRE_APP="true"
      EXPECT_WORKFLOW="true"
      EXPECT_APPCAST="true"
      shift
      ;;
    --release-package)
      [[ $# -ge 2 ]] || fail "--release-package requires a path"
      RELEASE_PACKAGE_PATH="$2"
      REQUIRE_SIGNED_APPCAST_ITEM="true"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

cd "$ROOT_DIR"

require_file "Package.swift"
require_file "Sources/FacePass/FacePassApp.swift"
require_file "Sources/FacePass/MenuBarContentView.swift"
require_file "script/build_and_run.sh"

if ! grep -Eq 'Sparkle|sparkle-project/Sparkle' Package.swift; then
  fail "Package.swift does not declare Sparkle."
fi

if ! grep -Eq 'import Sparkle|SPUUpdater|SPUStandardUpdaterController' Sources/FacePass/*.swift; then
  fail "FacePass app/menu sources do not expose Sparkle updater integration markers."
fi

if ! grep -Fq "$EXPECTED_FEED_URL" script/build_and_run.sh Sources/FacePass/*.swift; then
  fail "Expected Sparkle feed URL was not found in app/build sources: $EXPECTED_FEED_URL"
fi

if ! grep -Fq "SUFeedURL" script/build_and_run.sh; then
  fail "script/build_and_run.sh generates Info.plist but does not include SUFeedURL."
fi

if ! grep -Fq "SUPublicEDKey" script/build_and_run.sh; then
  fail "script/build_and_run.sh generates Info.plist but does not include SUPublicEDKey."
fi

if ! grep -Fq "FACEPASS_SPARKLE_PUBLIC_ED_KEY" script/build_and_run.sh; then
  fail "script/build_and_run.sh does not source SUPublicEDKey from FACEPASS_SPARKLE_PUBLIC_ED_KEY."
fi

if [[ -n "$APP_BUNDLE_PATH" ]]; then
  local_info_plist="$APP_BUNDLE_PATH/Contents/Info.plist"
  [[ -d "$APP_BUNDLE_PATH" ]] || fail "App bundle not found: $APP_BUNDLE_PATH"
  require_file "$local_info_plist"

  actual_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$local_info_plist" 2>/dev/null || true)"
  [[ "$actual_feed_url" == "$EXPECTED_FEED_URL" ]] || fail "SUFeedURL mismatch: expected $EXPECTED_FEED_URL, got ${actual_feed_url:-<missing>}"

  public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$local_info_plist" 2>/dev/null || true)"
  [[ -n "$public_key" ]] || fail "SUPublicEDKey is missing from $local_info_plist"
  if [[ "$public_key" =~ (TODO|PLACEHOLDER|REPLACE|example|changeme) ]]; then
    fail "SUPublicEDKey appears to be a placeholder."
  fi
else
  if [[ "$REQUIRE_APP" == "true" ]]; then
    fail "Strict release verification requires --app /path/to/FacePass.app."
  fi
  note "Skipping built app Info.plist checks; pass --app /path/to/FacePass.app after staging a build."
fi

if [[ -f ".github/workflows/release.yml" ]]; then
  if command -v ruby >/dev/null 2>&1; then
    ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' ".github/workflows/release.yml"
  else
    note "ruby not available; skipped YAML syntax validation for .github/workflows/release.yml"
  fi

  if grep -Eq '^[[:space:]]+branches:' ".github/workflows/release.yml"; then
    fail "release.yml contains a push branches trigger; formal public releases must be tag-triggered."
  fi
  if ! grep -Eq '^[[:space:]]+tags:' ".github/workflows/release.yml"; then
    fail "release.yml does not contain a push tags trigger."
  fi
  if ! grep -Eq 'v\*|v[0-9]|refs/tags' ".github/workflows/release.yml"; then
    fail "release.yml does not appear constrained to release version tags."
  fi
  if grep -Fq 'dist/release/FacePass-${RELEASE_VERSION#v}.zip' ".github/workflows/release.yml"; then
    fail "release.yml still references the old ZIP final artifact path; official release packages must be DMG files."
  fi
  if ! grep -Fq 'dist/release/FacePass-${RELEASE_VERSION#v}.dmg' ".github/workflows/release.yml"; then
    fail "release.yml does not reference the official DMG release package path."
  fi
  if ! grep -Fq 'gh release upload "$RELEASE_VERSION" "$PACKAGE" "$PACKAGE.sha256" --clobber' ".github/workflows/release.yml"; then
    fail "release.yml does not upload the DMG and DMG sha256 to GitHub Release."
  fi
  if ! grep -Fq 'cp "dist/release/FacePass-${RELEASE_VERSION#v}.dmg" "$APPCAST_INPUT/"' ".github/workflows/release.yml"; then
    fail "release.yml does not feed the DMG package into Sparkle appcast generation."
  fi
  if ! grep -Fq -- '--release-package "dist/release/FacePass-${RELEASE_VERSION#v}.dmg"' ".github/workflows/release.yml"; then
    fail "release.yml does not verify the Sparkle release gate against the DMG package."
  fi
  if ! grep -Fq -- 'gh release edit "$RELEASE_VERSION" --draft=false' ".github/workflows/release.yml"; then
    fail "release.yml does not publish the draft GitHub Release after the release gate passes."
  fi
else
  if [[ "$EXPECT_WORKFLOW" == "true" ]]; then
    fail "Strict release verification expected .github/workflows/release.yml."
  fi
  note "Skipping release workflow checks; .github/workflows/release.yml is not present."
fi

if [[ -f "website/updates/appcast.xml" ]]; then
  validate_xml "website/updates/appcast.xml"

  if grep -Eq '(url|sparkle:url)="(http://|file://|[^"]*(localhost|127\.0\.0\.1))' "website/updates/appcast.xml"; then
    fail "appcast contains a non-public or insecure package/feed URL."
  fi

  if grep -Eq '<enclosure[[:space:]>]' "website/updates/appcast.xml"; then
    if ! grep -Eq 'https://github\.com/.+/releases/download/' "website/updates/appcast.xml"; then
      fail "appcast package URL does not point at GitHub Releases."
    fi
    if grep -Eq 'https://github\.com/.+/releases/download/[^"]+\.zip(["?]|$)' "website/updates/appcast.xml"; then
      fail "appcast package URL points at a ZIP; official release packages must be DMG files."
    fi
    if ! grep -Eq 'https://github\.com/.+/releases/download/[^"]+\.dmg(["?]|$)' "website/updates/appcast.xml"; then
      fail "appcast package URL does not point at a DMG release package."
    fi
    if ! grep -Eq 'sparkle:edSignature=' "website/updates/appcast.xml"; then
      fail "appcast enclosure is missing a Sparkle 2 edSignature."
    fi
  else
    note "Appcast has no update items; this is acceptable for smoke/placeholder validation."
    if [[ "$REQUIRE_SIGNED_APPCAST_ITEM" == "true" ]]; then
      fail "Release package verification requires a signed appcast enclosure."
    fi
  fi

  if [[ "$REQUIRE_SIGNED_APPCAST_ITEM" == "true" ]]; then
    require_file "$RELEASE_PACKAGE_PATH"
    release_package_name="$(basename "$RELEASE_PACKAGE_PATH")"
    if [[ "$release_package_name" != *.dmg ]]; then
      fail "Release package must be a DMG for official Sparkle releases: $release_package_name"
    fi
    if ! grep -Fq "$release_package_name" "website/updates/appcast.xml"; then
      fail "appcast does not reference release package $release_package_name."
    fi
    release_version="${release_package_name#FacePass-}"
    release_version="${release_version%.dmg}"
    expected_release_download_path="/releases/download/v${release_version}/${release_package_name}"
    if ! grep -Fq "$expected_release_download_path" "website/updates/appcast.xml"; then
      fail "appcast does not reference the expected GitHub Releases tag download path: $expected_release_download_path"
    fi
  fi
else
  if [[ "$EXPECT_APPCAST" == "true" ]]; then
    fail "Strict release verification expected website/updates/appcast.xml."
  fi
  note "Skipping appcast checks; website/updates/appcast.xml is not present."
fi

echo "Sparkle release/update verification completed."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_HELPER="$ROOT_DIR/script/phase8_auraface_artifact.sh"
BUILD_RUNNER="$ROOT_DIR/script/build_and_run.sh"
MODE="run"

usage() {
  cat <<'USAGE'
Usage: script/setup_and_run.sh [--verify] [--logs] [--help]

Prepare the ignored local FacePass recognition model artifact when needed,
then build and run the app.

Modes:
  --verify  Prepare or verify the model, then build and verify without launch.
  --logs    Prepare or verify the model, launch the app, then stream logs.
  --help    Show this help text.

Python note:
  Model conversion uses the legacy coremltools path and requires Python 3.8.
  If FACEPASS_PHASE8_LEGACY_PYTHON is unset, this script tries python3.8.
  Set FACEPASS_PHASE8_LEGACY_PYTHON to override.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      MODE="verify"
      ;;
    --logs)
      MODE="logs"
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

require_file() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "Required executable script not found: $path" >&2
    exit 1
  fi
}

python_minor_version() {
  "$1" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
}

select_legacy_python() {
  if [[ -n "${FACEPASS_PHASE8_LEGACY_PYTHON:-}" ]]; then
    if ! command -v "$FACEPASS_PHASE8_LEGACY_PYTHON" >/dev/null 2>&1; then
      echo "FACEPASS_PHASE8_LEGACY_PYTHON is set but not executable: $FACEPASS_PHASE8_LEGACY_PYTHON" >&2
      exit 1
    fi
    echo "Using FACEPASS_PHASE8_LEGACY_PYTHON=$FACEPASS_PHASE8_LEGACY_PYTHON"
    return
  fi

  local candidate
  for candidate in python3.8; do
    if command -v "$candidate" >/dev/null 2>&1; then
      export FACEPASS_PHASE8_LEGACY_PYTHON="$candidate"
      echo "Using legacy conversion Python: $FACEPASS_PHASE8_LEGACY_PYTHON"
      return
    fi
  done

  cat >&2 <<'EOF'
FacePass needs Python 3.8 to convert the pinned AuraFace model with
the legacy coremltools dependency stack. Install python3.8, or set
FACEPASS_PHASE8_LEGACY_PYTHON to a compatible interpreter.
EOF
  exit 1
}

prepare_model_if_needed() {
  if "$ARTIFACT_HELPER" verify-bundled >/dev/null 2>&1; then
    "$ARTIFACT_HELPER" verify-bundled
    return
  fi

  echo "Bundled Core ML model artifact is missing or invalid; preparing it under ignored Artifacts/."
  select_legacy_python
  local version
  version="$(python_minor_version "$FACEPASS_PHASE8_LEGACY_PYTHON")"
  case "$version" in
    3.8)
      ;;
    *)
      echo "Legacy conversion requires Python 3.8; got $version from $FACEPASS_PHASE8_LEGACY_PYTHON" >&2
      exit 1
      ;;
  esac

  "$ARTIFACT_HELPER" prepare-bundled
}

require_file "$ARTIFACT_HELPER"
require_file "$BUILD_RUNNER"

cd "$ROOT_DIR"
prepare_model_if_needed

case "$MODE" in
  verify)
    exec "$BUILD_RUNNER" --verify
    ;;
  logs)
    exec "$BUILD_RUNNER" --logs
    ;;
  run)
    exec "$BUILD_RUNNER"
    ;;
esac

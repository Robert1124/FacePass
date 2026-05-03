#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION="af6d057c9b0ec4071d4c49c80e3539258798b609"
MODEL_NAME="glintr100.onnx"
DOWNLOAD_URL="https://huggingface.co/fal/AuraFace-v1/resolve/$REVISION/$MODEL_NAME"
EXPECTED_SHA256="a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60"
EXPECTED_SIZE="260694151"
ARTIFACT_DIR="$ROOT_DIR/Artifacts/Phase8/AuraFace-v1/$REVISION"
ONNX_PATH="$ARTIFACT_DIR/$MODEL_NAME"
COREML_DIR="$ARTIFACT_DIR/coreml"
MLPACKAGE_PATH="$COREML_DIR/glintr100-fp16.mlpackage"
VENV_DIR="$ROOT_DIR/Artifacts/Phase8/venv"
PIP_CACHE_DIR="$ROOT_DIR/Artifacts/Phase8/pip-cache"
REQUIREMENTS_PATH="$ROOT_DIR/script/phase8-conversion-requirements.txt"
LEGACY_VENV_DIR="${FACEPASS_PHASE8_LEGACY_VENV_DIR:-$ROOT_DIR/Artifacts/Phase8/legacy-conversion-venv}"
LEGACY_PIP_CACHE_DIR="${FACEPASS_PHASE8_LEGACY_PIP_CACHE_DIR:-$ROOT_DIR/Artifacts/Phase8/legacy-pip-cache}"
LEGACY_REQUIREMENTS_PATH="$ROOT_DIR/script/phase8-legacy-conversion-requirements.txt"
LEGACY_COREML_DIR="$ARTIFACT_DIR/coreml-legacy"
LEGACY_MLMODEL_PATH="$LEGACY_COREML_DIR/glintr100-legacy.mlmodel"
LEGACY_OPSET10_ONNX_PATH="$ARTIFACT_DIR/glintr100-opset10-derived.onnx"
LEGACY_COREMLTOOLS_WHEEL_URL="https://files.pythonhosted.org/packages/86/6d/4c3bfb5581af66b186ea3c43c7458ba65136f0fb19ac01b9cd8fa51cfbcd/coremltools-4.1-cp38-none-macosx_10_16_intel.whl"
EXPECTED_LEGACY_MLMODEL_SHA256S=(
  "8e3204d64aad48970c91be2b697d9fb1e88611eded49d5adc49c1fe9453bb3d9"
  "c4d7b18e48954600631de30431d63515235ba6bdc44c3e5e150161cc631d4437"
)
EXPECTED_LEGACY_MLMODEL_SIZE="260665538"
PYTHON_BIN="${FACEPASS_PHASE8_PYTHON:-python3}"
LEGACY_PYTHON_BIN="${FACEPASS_PHASE8_LEGACY_PYTHON:-}"

usage() {
  cat <<'USAGE'
Usage: script/phase8_auraface_artifact.sh <command>

Commands:
  venv         Create/update ignored local dev conversion venv.
  env          Print local conversion tool versions.
  download     Download only the approved pinned glintr100.onnx artifact.
  verify       Verify local ONNX SHA256 and byte size.
  metadata     Print ONNX model input/output metadata.
  convert-fp16 Attempt fp16-first ONNX-to-Core ML conversion.
  legacy-spike Create isolated legacy converter venv and try legacy ONNX conversion.
  prepare-bundled
               Download, verify, legacy-convert, and verify the app-bundled .mlmodel.
  verify-bundled
               Verify and print the app-bundled legacy Core ML artifact.
  checksum     Print generated Core ML artifact checksums, if present.

Environment overrides:
  FACEPASS_PHASE8_PYTHON              Python used by env/metadata/convert-fp16.
  FACEPASS_PHASE8_LEGACY_PYTHON       Python 3.8 host for legacy-spike.
  FACEPASS_PHASE8_LEGACY_VENV_DIR     Ignored legacy-spike venv path.
  FACEPASS_PHASE8_LEGACY_PIP_CACHE_DIR Ignored legacy-spike pip cache path.
USAGE
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

matches_expected_legacy_mlmodel_sha256() {
  local actual_sha256="$1"
  local expected_sha256
  for expected_sha256 in "${EXPECTED_LEGACY_MLMODEL_SHA256S[@]}"; do
    if [[ "$actual_sha256" == "$expected_sha256" ]]; then
      return 0
    fi
  done
  return 1
}

print_expected_legacy_mlmodel_sha256s() {
  local expected_sha256
  for expected_sha256 in "${EXPECTED_LEGACY_MLMODEL_SHA256S[@]}"; do
    echo "  - $expected_sha256" >&2
  done
}

print_env() {
  sw_vers || true
  if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -version
  else
    echo "xcodebuild: not found"
  fi
  if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    "$PYTHON_BIN" --version
    "$PYTHON_BIN" - <<'PY'
import importlib.metadata
for package in ("coremltools", "onnx", "onnxruntime", "numpy"):
    try:
        print(f"{package}: {importlib.metadata.version(package)}")
    except importlib.metadata.PackageNotFoundError:
        print(f"{package}: not installed")
PY
  else
    echo "$PYTHON_BIN: not found"
  fi
}

create_venv() {
  mkdir -p "$(dirname "$VENV_DIR")" "$PIP_CACHE_DIR"
  python3 -m venv "$VENV_DIR"
  PIP_CACHE_DIR="$PIP_CACHE_DIR" "$VENV_DIR/bin/python" -m pip install --requirement "$REQUIREMENTS_PATH"
  "$VENV_DIR/bin/python" -m pip freeze
}

download_model() {
  mkdir -p "$ARTIFACT_DIR"
  if [[ -f "$ONNX_PATH" ]]; then
    echo "Existing artifact found at $ONNX_PATH"
    if verify_model; then
      return
    fi
    echo "Existing ONNX artifact is invalid; downloading the pinned artifact again." >&2
    rm -f "$ONNX_PATH"
  fi
  curl --fail --location --proto '=https' --tlsv1.2 --output "$ONNX_PATH.tmp" "$DOWNLOAD_URL"
  mv "$ONNX_PATH.tmp" "$ONNX_PATH"
  verify_model
}

verify_model() {
  if [[ ! -f "$ONNX_PATH" ]]; then
    echo "Missing ONNX artifact: $ONNX_PATH" >&2
    exit 1
  fi
  actual_sha="$(sha256 "$ONNX_PATH")"
  actual_size="$(file_size "$ONNX_PATH")"
  echo "ONNX path: $ONNX_PATH"
  echo "ONNX SHA256: $actual_sha"
  echo "ONNX size: $actual_size"
  if [[ "$actual_sha" != "$EXPECTED_SHA256" ]]; then
    echo "SHA256 mismatch. Expected $EXPECTED_SHA256" >&2
    exit 1
  fi
  if [[ "$actual_size" != "$EXPECTED_SIZE" ]]; then
    echo "Size mismatch. Expected $EXPECTED_SIZE" >&2
    exit 1
  fi
}

verify_legacy_coreml() {
  if [[ ! -f "$LEGACY_MLMODEL_PATH" ]]; then
    echo "Missing bundled Core ML artifact: $LEGACY_MLMODEL_PATH" >&2
    exit 1
  fi

  actual_sha="$(sha256 "$LEGACY_MLMODEL_PATH")"
  actual_size="$(file_size "$LEGACY_MLMODEL_PATH")"
  echo "Bundled Core ML path: $LEGACY_MLMODEL_PATH"
  echo "Bundled Core ML SHA256: $actual_sha"
  echo "Bundled Core ML size: $actual_size"
  if ! matches_expected_legacy_mlmodel_sha256 "$actual_sha"; then
    echo "Bundled Core ML SHA256 mismatch. Expected one of:" >&2
    print_expected_legacy_mlmodel_sha256s
    exit 1
  fi
  if [[ "$actual_size" != "$EXPECTED_LEGACY_MLMODEL_SIZE" ]]; then
    echo "Bundled Core ML size mismatch. Expected $EXPECTED_LEGACY_MLMODEL_SIZE" >&2
    exit 1
  fi
}

print_metadata() {
  verify_model >/dev/null
  "$PYTHON_BIN" - "$ONNX_PATH" <<'PY'
import sys

try:
    import onnx
except ModuleNotFoundError:
    print("onnx: not installed; cannot inspect ONNX graph metadata.", file=sys.stderr)
    sys.exit(2)

model_path = sys.argv[1]
model = onnx.load(model_path)
print(f"ir_version: {model.ir_version}")
print("opset_imports:")
for opset in model.opset_import:
    domain = opset.domain or "ai.onnx"
    print(f"  {domain}: {opset.version}")

def type_name(value_info):
    tensor_type = value_info.type.tensor_type
    elem = tensor_type.elem_type
    return onnx.TensorProto.DataType.Name(elem)

def shape(value_info):
    dims = []
    tensor_shape = value_info.type.tensor_type.shape
    for dim in tensor_shape.dim:
        if dim.dim_param:
            dims.append(dim.dim_param)
        elif dim.HasField("dim_value"):
            dims.append(dim.dim_value)
        else:
            dims.append("?")
    return dims

print("inputs:")
for item in model.graph.input:
    print(f"  {item.name}: dtype={type_name(item)} shape={shape(item)}")

print("outputs:")
for item in model.graph.output:
    print(f"  {item.name}: dtype={type_name(item)} shape={shape(item)}")
PY
}

convert_fp16() {
  verify_model >/dev/null
  mkdir -p "$COREML_DIR"
  "$PYTHON_BIN" - "$ONNX_PATH" "$MLPACKAGE_PATH" <<'PY'
import pathlib
import shutil
import sys

try:
    import coremltools as ct
except ModuleNotFoundError:
    print("coremltools: not installed; cannot convert ONNX to Core ML.", file=sys.stderr)
    sys.exit(2)

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
if destination.exists():
    shutil.rmtree(destination)

if not hasattr(ct.converters, "onnx"):
    raise RuntimeError(
        "Installed coremltools does not expose ct.converters.onnx; "
        "direct ONNX conversion is unavailable in this environment."
    )

mlmodel = ct.converters.onnx.convert(
    model=str(source),
    minimum_deployment_target=ct.target.macOS13,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.save(str(destination))
print(f"Saved {destination}")
PY
}

legacy_spike() {
  verify_model
  mkdir -p "$LEGACY_PIP_CACHE_DIR" "$LEGACY_COREML_DIR"
  select_legacy_python
  "$LEGACY_PYTHON_BIN" -m venv "$LEGACY_VENV_DIR"

  echo "Legacy Python:"
  "$LEGACY_VENV_DIR/bin/python" --version
  echo "Legacy requirements: $LEGACY_REQUIREMENTS_PATH"
  echo "Checking binary-compatible legacy converter dependencies."
  if ! PIP_CACHE_DIR="$LEGACY_PIP_CACHE_DIR" "$LEGACY_VENV_DIR/bin/python" -m pip install --only-binary=:all: --requirement "$LEGACY_REQUIREMENTS_PATH"; then
    echo "Legacy converter dependency install failed on this Python/macOS environment." >&2
    echo "NumPy compatibility check for the coremltools 4.1 dependency range:" >&2
    PIP_CACHE_DIR="$LEGACY_PIP_CACHE_DIR" "$LEGACY_VENV_DIR/bin/python" -m pip install --only-binary=:all: 'numpy>=1.14.5,<1.20' || true
    echo "Stopping before conversion; no ONNX-derived or Core ML artifact was generated." >&2
    exit 2
  fi
  install_legacy_coremltools

  "$LEGACY_VENV_DIR/bin/python" - "$ONNX_PATH" "$LEGACY_MLMODEL_PATH" "$LEGACY_OPSET10_ONNX_PATH" <<'PY'
import hashlib
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
opset10_destination = pathlib.Path(sys.argv[3])

try:
    import coremltools as ct
    import onnx
except ModuleNotFoundError as error:
    print(f"Missing legacy conversion dependency: {error}", file=sys.stderr)
    sys.exit(2)

print(f"coremltools: {ct.__version__}")
print(f"onnx: {onnx.__version__}")
print(f"ct.converters.onnx available: {hasattr(ct.converters, 'onnx')}")
if not hasattr(ct.converters, "onnx"):
    raise RuntimeError("Installed legacy coremltools does not expose ct.converters.onnx.")

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def convert_to_coreml(onnx_path, mlmodel_path):
    if mlmodel_path.exists():
        mlmodel_path.unlink()
    model = ct.converters.onnx.convert(model=str(onnx_path))
    model.save(str(mlmodel_path))
    print(f"Core ML artifact: {mlmodel_path}")
    print("Core ML artifact type: .mlmodel")
    print(f"Core ML SHA256: {sha256(mlmodel_path)}")
    print(f"Core ML size: {mlmodel_path.stat().st_size}")

try:
    convert_to_coreml(source, destination)
except Exception as error:
    message = str(error)
    print(f"Legacy opset-11 conversion failed: {type(error).__name__}: {message}", file=sys.stderr)
    if "opset" not in message.lower():
        raise

    print("Failure appears opset-related; attempting official ONNX version_converter downgrade to opset 10.")
    model = onnx.load(str(source))
    converted = onnx.version_converter.convert_version(model, 10)
    onnx.checker.check_model(converted)
    if opset10_destination.exists():
        opset10_destination.unlink()
    onnx.save(converted, str(opset10_destination))
    print(f"Derived ONNX artifact: {opset10_destination}")
    print("Derived ONNX source: official onnx.version_converter.convert_version(..., 10)")
    print(f"Derived ONNX SHA256: {sha256(opset10_destination)}")
    print(f"Derived ONNX size: {opset10_destination.stat().st_size}")
    convert_to_coreml(opset10_destination, destination)
PY
}

prepare_bundled() {
  download_model
  legacy_spike
  verify_legacy_coreml
}

select_legacy_python() {
  if [[ -n "$LEGACY_PYTHON_BIN" ]]; then
    return
  fi

  local candidate
  for candidate in python3.8; do
    if command -v "$candidate" >/dev/null 2>&1; then
      LEGACY_PYTHON_BIN="$candidate"
      echo "Using legacy conversion Python: $LEGACY_PYTHON_BIN"
      return
    fi
  done

  echo "Legacy conversion requires Python 3.8. Set FACEPASS_PHASE8_LEGACY_PYTHON to a compatible interpreter." >&2
  exit 1
}

install_legacy_coremltools() {
  if "$LEGACY_VENV_DIR/bin/python" - <<'PY' >/dev/null 2>&1
import coremltools as ct
raise SystemExit(0 if ct.__version__ == "4.1" else 1)
PY
  then
    return
  fi

  if PIP_CACHE_DIR="$LEGACY_PIP_CACHE_DIR" "$LEGACY_VENV_DIR/bin/python" -m pip install --only-binary=:all: 'coremltools==4.1'; then
    return
  fi

  if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "coremltools==4.1 was not installable through pip, and the manual legacy wheel fallback requires x86_64 macOS." >&2
    exit 2
  fi

  echo "pip did not accept the legacy coremltools==4.1 wheel tag; installing the pinned official cp38 Intel wheel manually."
  local wheel_dir wheel_path site_packages
  wheel_dir="$(mktemp -d "${TMPDIR:-/tmp}/facepass-coremltools-wheel.XXXXXX")"
  wheel_path="$wheel_dir/coremltools-4.1-cp38-none-macosx_10_16_intel.whl"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$wheel_path" "$LEGACY_COREMLTOOLS_WHEEL_URL"
  site_packages="$("$LEGACY_VENV_DIR/bin/python" - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"
  "$LEGACY_VENV_DIR/bin/python" - "$wheel_path" "$site_packages" <<'PY'
import pathlib
import sys
import zipfile

wheel = pathlib.Path(sys.argv[1])
site_packages = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(wheel) as archive:
    archive.extractall(site_packages)
print(f"Installed {wheel.name} into {site_packages}")
PY
  rm -rf "$wheel_dir"
  "$LEGACY_VENV_DIR/bin/python" - <<'PY'
import coremltools as ct
if ct.__version__ != "4.1":
    raise SystemExit(f"Unexpected coremltools version: {ct.__version__}")
print(f"coremltools manual install verified: {ct.__version__}")
PY
}

checksum_coreml() {
  if [[ ! -e "$MLPACKAGE_PATH" ]]; then
    echo "Missing Core ML artifact: $MLPACKAGE_PATH" >&2
    exit 1
  fi
  find "$MLPACKAGE_PATH" -type f -print0 | sort -z | xargs -0 shasum -a 256
}

command="${1:-}"
case "$command" in
  venv)
    create_venv
    ;;
  env)
    print_env
    ;;
  download)
    download_model
    ;;
  verify)
    verify_model
    ;;
  metadata)
    print_metadata
    ;;
  convert-fp16)
    convert_fp16
    ;;
  legacy-spike)
    legacy_spike
    ;;
  prepare-bundled)
    prepare_bundled
    ;;
  verify-bundled)
    verify_legacy_coreml
    ;;
  checksum)
    checksum_coreml
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

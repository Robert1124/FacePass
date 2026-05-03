# Recognition Model

FacePass currently uses a local face-recognition prototype.

## Current Model Path

The prototype is built around AuraFace-v1 `glintr100.onnx`, converted locally to a Core ML artifact for app bundling.

Normal source users should use the one-command setup flow:

```bash
./script/setup_and_run.sh
```

That script verifies the converted local Core ML source artifact and prepares it when it is missing or invalid. The artifact path is:

```text
Artifacts/Phase8/AuraFace-v1/af6d057c9b0ec4071d4c49c80e3539258798b609/coreml-legacy/glintr100-legacy.mlmodel
```

During app staging, `script/build_and_run.sh` verifies that file's expected size and SHA256, compiles it with `coremlcompiler`, embeds the resulting `.mlmodelc` under `Contents/Resources/Models/`, and then publishes `dist/FacePass.app`. `script/setup_and_run.sh` performs any needed local model download/conversion before delegating to the build script. The app itself does not download or convert model files and does not add network behavior.

## Local Model Preparation

Recommended flow:

```bash
./script/setup_and_run.sh
```

Prepare and verify the app build without launching:

```bash
./script/setup_and_run.sh --verify
```

Launch and stream logs:

```bash
./script/setup_and_run.sh --logs
```

The setup script uses `script/phase8_auraface_artifact.sh` as the advanced local artifact helper when the bundled Core ML artifact is missing or invalid. Conversion uses the legacy `coremltools==4.1` path and requires Python 3.8. If `FACEPASS_PHASE8_LEGACY_PYTHON` is unset, `script/setup_and_run.sh` tries `python3.8`; set `FACEPASS_PHASE8_LEGACY_PYTHON` to override.

Advanced fallback:

```bash
FACEPASS_PHASE8_LEGACY_PYTHON=python3.8 ./script/phase8_auraface_artifact.sh prepare-bundled
```

The helper performs these steps:

1. Downloads the pinned AuraFace-v1 `glintr100.onnx` from Hugging Face revision `af6d057c9b0ec4071d4c49c80e3539258798b609`.
2. Verifies the ONNX artifact:

```text
Artifacts/Phase8/AuraFace-v1/af6d057c9b0ec4071d4c49c80e3539258798b609/glintr100.onnx
SHA256: a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60
Size: 260694151 bytes
```

3. Creates an ignored legacy conversion virtualenv under `Artifacts/Phase8/legacy-conversion-venv`, using `script/phase8-legacy-conversion-requirements.txt`.
4. Runs the legacy `coremltools==4.1` direct ONNX conversion path. If the original opset conversion fails for an opset-related reason, the helper derives an opset-10 ONNX file with `onnx.version_converter.convert_version(..., 10)` and converts that derived file.
5. Verifies and prints the app-bundled Core ML source artifact:

```text
Artifacts/Phase8/AuraFace-v1/af6d057c9b0ec4071d4c49c80e3539258798b609/coreml-legacy/glintr100-legacy.mlmodel
SHA256: 8e3204d64aad48970c91be2b697d9fb1e88611eded49d5adc49c1fe9453bb3d9
Size: 260665538 bytes
```

You can re-check the generated bundled artifact without downloading or converting:

```bash
./script/phase8_auraface_artifact.sh verify-bundled
```

Then build or verify the app:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh
```

Python compatibility note: the legacy conversion requirements use `coremltools==4.1`, which depends on `numpy>=1.14.5,<1.20`. That dependency range is not binary-compatible with the Python 3.9/3.11/3.12 interpreters observed in current local and GitHub Actions environments. Use a Python 3.8 interpreter for `FACEPASS_PHASE8_LEGACY_PYTHON` unless the legacy dependency stack has been revalidated.

The model files are intentionally not committed to this source repository:

- `Artifacts/Phase8/AuraFace-v1/.../glintr100.onnx`
- `Artifacts/Phase8/AuraFace-v1/.../coreml-legacy/glintr100-legacy.mlmodel`
- generated `.mlmodelc` bundles
- Python virtualenvs and conversion caches

The setup script and local build script expect the converted model artifact under `Artifacts/` when staging the recognition-enabled app.

## Source And License Notes

Recorded development source:

- Source: <https://huggingface.co/fal/AuraFace-v1>
- File: `glintr100.onnx`
- Pinned revision: `af6d057c9b0ec4071d4c49c80e3539258798b609`
- Recorded model license: Apache-2.0

If you redistribute model artifacts or binaries that include them, review the upstream model license and include any required notices.

## Runtime Behavior

- Enrollment stores encrypted local template data, not raw photos.
- Observe, lock-screen, and authorization-prompt recognition can evaluate multiple visible face candidates against the single stored template.
- Enrollment capture still expects one valid face per capture.
- Recognition runs in short camera windows and stops after success, failure, timeout, or cancellation.

## Current Limitations

This is not production biometric security.

Known gaps:

- No robust liveness check yet
- Photo/video spoof resistance needs improvement
- No complete real local FAR/FRR calibration dataset
- No multi-role permission model yet
- No multi-user enrollment or permission levels yet

## Roadmap

1. Add stronger liveness/spoof resistance, especially to reduce photo-based bypass risk.
2. Collect local validation data and calibrate false accept / false reject behavior.
3. Add roles and permissions, such as lock-screen-only and full approved-action roles.

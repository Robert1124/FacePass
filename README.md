# FacePass

![FacePass macOS menu-bar helper header](docs/assets/facepass-readme-header-en.png)

FacePass is a native macOS menu-bar helper for people who want a quick local unlock and password-fill workflow on their own Mac.

It is inspired by the idea of BLEUnlock, but it does not use BLEUnlock code. FacePass uses a local camera-based recognition gate instead of Bluetooth proximity.

[Official Website](https://facepass.robertw.me)

[中文说明](README.zh-CN.md)

## What It Does

FacePass currently supports two narrow targets:

- Lock-screen assist: when enabled, FacePass can run local face recognition, type your saved password, and press Return only while macOS is locked.
- Administrator/System Settings prompts: FacePass can detect approved macOS authorization password prompts, run local face recognition, and fill only the password value.

For administrator/System Settings prompts, FacePass does not click `OK`, `Continue`, `Modify Settings`, `Login`, or any other confirmation button. It does not press Return or submit the prompt.

## What It Is Not

FacePass is not Apple Face ID, Touch ID, or a replacement for macOS authentication.

FacePass does not support ordinary website or app password fields. It is intentionally scoped to the macOS lock screen and macOS administrator/System Settings authorization prompts.

## Current Features

- Native macOS 13+ Swift/SwiftUI menu-bar app
- Settings window with setup, automation, recognition, and status sections
- Keychain-backed password storage
- First-run setup flow for Camera and Accessibility permissions
- Short-lived camera sessions for local recognition
- Single local enrollment template with multiple local embeddings
- Lock-screen assist with opt-in recognition gate
- Administrator/System Settings prompt detection and value-only fill
- Automation conditions for automatic actions:
  - Wi-Fi connected
  - External monitor connected
  - Power state
  - Any/All selected condition matching


## Setup

1. Build and run FacePass.
2. Open the menu-bar app and complete setup.
3. Grant Camera permission.
4. Grant Accessibility permission.
5. Save your Mac login password in the Password section. FacePass stores it in Keychain and does not show it again.
6. Capture enrollment samples in Recognition.
7. Enable lock-screen assist or administrator/System Settings prompt handling as needed.

## Privacy And Safety

FacePass keeps processing local.

- Passwords are stored only in macOS Keychain.
- FacePass does not store raw camera frames, photos, or screenshots.
- Camera sessions are short-lived and start only when needed.
- Face recognition templates are local encrypted template data, not raw images.
- FacePass does not upload face data, passwords, unlock state, Wi-Fi details, display identifiers, or environment data.
- FacePass has no analytics, telemetry, cloud sync, or network service.

## Build From Source

Requirements:

- macOS 13+
- Xcode command line tools
- Swift 5.9+

Run tests:

```bash
swift test
```

Build and run the app:

```bash
./script/setup_and_run.sh
```

This prepares the ignored local recognition model artifact if it is missing or invalid, then builds, stages, and launches a physical app bundle at `dist/FacePass.app`. Use `./script/setup_and_run.sh --verify` to prepare the model and verify the app build without launching it. Verification fails if `dist/FacePass.app` is a symlink instead of a complete bundle. If FileProvider or iCloud metadata prevents strict codesign verification in `dist`, verification publishes and reports a physical fallback app at `~/Library/Caches/FacePass/dist/FacePass.app`. Use `./script/setup_and_run.sh --logs` to launch and stream FacePass logs.

The setup script may download the pinned AuraFace `glintr100.onnx`, verify it, run the legacy Core ML conversion path, and verify the generated bundled artifact at `Artifacts/Phase8/.../coreml-legacy/glintr100-legacy.mlmodel`. Model artifacts remain under ignored `Artifacts/` and are intentionally not committed to the repository. The app itself does not add network behavior. See [Recognition Model](docs/recognition-model.md) for details, including the advanced manual artifact helper.

## Distribution Status

FacePass is currently source-first. Without an Apple Developer Program account, you can build and run locally, use ad-hoc signing, or use a local Apple Development certificate, but you cannot produce a Developer ID notarized app for trusted public direct download.

See [Distribution](docs/distribution.md) for details.

## Documentation

- [Static Website](website/)
- [Architecture](docs/architecture.md)
- [Security Model](docs/security-model.md)
- [Recognition Model](docs/recognition-model.md)
- [Authorization Prompt Detection](docs/prompt-detection.md)
- [Distribution](docs/distribution.md)
- [Development Roadmap](docs/roadmap.md)
- [Third-Party Notices](NOTICE.md)

## Roadmap

Next planned work:

1. Stronger face-recognition safety, including better liveness/spoof resistance so a photo is less likely to pass.
2. Better recognition calibration with local false-accept and false-reject testing.
3. Multi-role permissions, such as one enrolled face that can only unlock the lock screen and another role that can use all approved FacePass actions.
4. Packaging improvements for signed and notarized distribution when Developer ID credentials are available.

## License

FacePass is released under the MIT License. See [LICENSE](LICENSE).

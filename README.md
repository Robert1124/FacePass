# FacePass

![FacePass macOS menu-bar helper header](docs/assets/facepass-readme-header-en.png)

FacePass is a native macOS menu-bar helper for people who want a quick local unlock and password-fill workflow on their own Mac.

It is inspired by the idea of BLEUnlock, but it does not use BLEUnlock code. FacePass uses a local camera-based recognition gate instead of Bluetooth proximity.

[Official Website](https://facepass.robertw.me)

[Sponsor FacePass](https://github.com/sponsors/Robert1124)

[Join the iPhone Companion TestFlight](https://testflight.apple.com/join/p3zBMEBY)

[中文说明](README.zh-CN.md)

## What It Does

FacePass currently supports two narrow targets and configurable provider routing:

- Lock-screen assist: when enabled, FacePass can run local face recognition, type your saved password, and press Return only while macOS is locked.
- Administrator/System Settings prompts: FacePass can detect approved macOS authorization password prompts, run local face recognition or use paired-iPhone approval according to Unlock Mode, and fill only the password value.

For administrator/System Settings prompts, FacePass does not click `OK`, `Continue`, `Modify Settings`, `Login`, or any other confirmation button. It does not press Return or submit the prompt.

For the lock screen, you can enable local recognition unlock, iPhone StandBy Unlock, or both. The Unlock Mode settings can also route lock-screen unlock to local recognition while allowing the paired iPhone to fill approved administrator/System Settings prompts. iPhone StandBy Unlock is a separate provider. It is not a supplement to Mac local recognition and does not use the Mac camera.

## What It Is Not

FacePass is not Apple Face ID, Touch ID, or a replacement for macOS authentication.

FacePass does not support ordinary website or app password fields. It is intentionally scoped to the macOS lock screen and approved macOS administrator/System Settings authorization prompts.

Generic LocalAuthentication prompts remain rejected.

## Setup

Start with the [official website setup guide](https://facepass.robertw.me/docs.html#start). It covers DMG and source installs, plus in-app permissions, Keychain password storage, recognition enrollment, and Unlock Mode setup.

## iPhone StandBy Unlock

iPhone StandBy Unlock lets a paired iPhone approve FacePass handling without running Mac local recognition. It is a separate provider that can be routed by Unlock Mode for lock-screen assist, approved administrator/System Settings prompt fill, or both.

The iPhone companion is available for external TestFlight testing: [Join FacePass on TestFlight](https://testflight.apple.com/join/p3zBMEBY).

- When the Mac is locked, a valid paired-iPhone approval can wake the display and use the same locked-session password typing path.
- When the Mac is unlocked and an approved administrator/System Settings prompt is present, a valid paired-iPhone approval can fill only the password value with no click, submit, or Return.
- The iPhone approval surface requires local device unlock/authentication before sending a signed local request.
- The iPhone never receives the Mac password, Mac face data, Mac camera frames, or local recognition result.
- FacePass does not use an external unlock server, APNs unlock path, WebSocket transport, telemetry, cloud sync, or paid network service for StandBy Unlock.

Implementation and verification details are in [iPhone StandBy Unlock implementation notes](docs/iphone-standby-unlock.md).

## Privacy And Safety

FacePass keeps processing local.

See the [official privacy page](https://facepass.robertw.me/privacy.html) for the user-facing privacy policy.

- Passwords are stored only in macOS Keychain.
- FacePass does not store raw camera frames, photos, or screenshots.
- Camera sessions are short-lived and start only when needed.
- Sensitive local recognition gates for lock-screen assist and approved administrator/System Settings prompt fill run for up to 10 seconds by default. Below-threshold usable face observations are retryable during that initial window and do not fail the gate early; hard failures still stop immediately. Recognition returns as soon as the required accepted matches are collected. If the first accepted match arrives late, only the existing bounded short follow-up capture path may collect the remaining required match. Camera capture still stops after success, timeout, cancellation, or failure.
- Face recognition templates are local encrypted template data, not raw images.
- FacePass does not upload passwords, face data, raw camera frames, unlock state, Wi-Fi details, display identifiers, or environment signals.
- FacePass has no analytics, telemetry, cloud sync, backend account service, external unlock server, APNs unlock path, WebSocket transport, or paid network service.
- StandBy Unlock stores paired iPhone public-key trust separately in Keychain, uses replay protection and a durable counter, and sends no Mac password or face data to the iPhone.

## Build From Source

Use the [official Build From Source guide](https://facepass.robertw.me/docs.html#build-from-source). It covers requirements, clone commands, verify/build commands, and test commands.

For deeper local build and packaging notes, see [Distribution](docs/distribution.md). For local recognition model artifact details, see [Recognition Model](docs/recognition-model.md).

## Documentation

- [Official Website Documentation](https://facepass.robertw.me/docs.html)
- [Official Privacy Policy](https://facepass.robertw.me/privacy.html)
- [Official Roadmap](https://facepass.robertw.me/roadmap.html)
- [Static Website Source](website/)
- [Architecture](docs/architecture.md)
- [Security Model](docs/security-model.md)
- [iPhone StandBy Unlock](docs/iphone-standby-unlock.md)
- [Recognition Model](docs/recognition-model.md)
- [Authorization Prompt Detection](docs/prompt-detection.md)
- [Distribution](docs/distribution.md)
- [Development Roadmap](docs/roadmap.md)
- [Third-Party Notices](NOTICE.md)

## Roadmap

See the [official FacePass roadmap](https://facepass.robertw.me/roadmap.html). Planned work stays within the local-helper boundary and must not claim Face ID, Touch ID, system biometrics, or macOS authentication replacement behavior.

## License

FacePass is released under the MIT License. See [LICENSE](LICENSE).

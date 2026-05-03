# Development Roadmap

## Current Version

The current version is a local macOS helper for:

- lock-screen assist through local recognition, iPhone StandBy Unlock, or both
- approved macOS administrator/System Settings authorization prompt value fill
- approved Apple Passwords app unlock prompt value fill

It is not Apple Face ID, Touch ID, or a macOS authentication replacement.

iPhone StandBy Unlock is an independent provider. `StandByUnlockIntent` requires local device authentication on the iPhone before sending signed paired-iPhone requests over local HTTP/Bonjour. The Mac verifies Mac identity, iPhone identity, timestamp, replay, durable counter, and action, then routes by current Mac state and Unlock Mode. Locked sessions can use the existing locked-session password typing plus Return path only after Mac-side gates pass. Unlocked approved prompts, including administrator/System Settings prompts and the Apple Passwords app unlock prompt, can receive value-only fill when the selected provider policy allows iPhone prompt fill. It does not use the Mac camera and does not send the Mac password to iPhone.

Settings now includes a dedicated Unlock Mode section for four policies: local face recognition only, paired iPhone approval only, both providers, and local face recognition for lock-screen unlock plus paired iPhone approval for approved unlocked-prompt fill. Password settings show only whether a Keychain password record is configured, not the value or length. Recognition settings include a user-adjustable similarity threshold with the current recommended default, in-memory enrollment capture progress, auto-save enrollment after required samples are captured, status text for the saved encrypted local template, and Clear Saved Face for deleting that template.

The iOS companion has moved from a non-buildable scaffold to a local iOS companion project at `Companion/iOS/FacePassCompanion.xcodeproj`. It includes `FacePassCompanion`, `FacePassCompanionCore`, `FacePassCompanionWidgetExtension`, and `FacePassCompanionTests` targets with iOS deployment target 17.0. Current source includes QR camera pairing with manual JSON fallback, paired status from the paired Mac plus the iPhone registration `displayName`, manual unlock request, forget pairing, app-side Live Activity start/update, a Keychain-backed iPhone device ID/signing-key baseline shared by the app and extension through the configured Keychain access group from processed Info.plist/entitlement values, durable per-Mac counter with OS file lock / cross-process coordination for app and extension increments, app-group endpoint cache, direct QR endpoint pairing when available, short Bonjour rediscovery fallback, `/v1/pair`, signed `/v1/standby-unlock`, a `FacePass Ready` Live Activity/Dynamic Island card with an `Unlock Mac` intent button, and an optional static FacePass Unlock widget alongside the Live Activity. The optional widget reuses the same signed local request boundary. The extension declares Local Network usage and `_facepass._tcp` Bonjour service access because the AppIntent can run there.

Verification is not complete: root `swift test` passes, the macOS app bundle verifies through `script/build_and_run.sh --verify`, and the iOS companion passes a generic `iphoneos` `xcodebuild build` with signing disabled plus signed physical-device build/install on the paired iPhone. Real-device manual verification is still required for QR camera scanning, Local Network prompt behavior, direct QR endpoint pairing, Bonjour rediscovery against the Mac including WidgetKit extension declarations, `/v1/pair`, `/v1/standby-unlock`, the StandBy card/AppIntent, iPhone-approved unlocked-prompt value fill, and the actual Mac lock-screen unlock path.

## Next Work

1. Stronger face-recognition safety
   - liveness checks
   - photo/video spoof resistance
   - better failed-recognition UX

2. Recognition calibration
   - local validation dataset
   - false accept / false reject measurement
   - threshold review before calling recognition production-grade

3. Multi-role permissions
   - lock-screen-only role
   - full approved-action role
   - clear UI for what each enrolled identity can do

4. Distribution
   - reproducible Developer ID-signed and notarized DMG release packaging
   - Developer ID signing support
   - notarization support
   - Sparkle 2 appcast publishing at `https://facepass.robertw.me/updates/appcast.xml`
   - GitHub Releases hosting for `FacePass-<version>.dmg` and `.dmg.sha256`
   - tag-triggered GitHub Actions releases for `v*` tags and explicit `workflow_dispatch`
   - clearer binary release instructions

5. iOS companion verification and packaging
   - add repeatable real-device smoke scripts for QR pairing, signed requests, Live Activity/AppIntent execution, and any optional widget surface
   - verify QR camera, Local Network prompt, Bonjour discovery, pairing, signed unlock requests, StandBy card, optional widget, and AppIntent on real devices
   - finalize signing and distribution configuration

## Not Planned

- ordinary website or app password-field autofill
- replacing macOS authentication
- cloud sync of face templates or passwords
- telemetry or analytics
- persistent camera monitoring
- external StandBy Unlock server, APNs dependency, WebSocket transport, cloud relay, or paid unlock service
- ordinary app or website password fill through the iPhone companion

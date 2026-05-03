# Architecture

FacePass is a native macOS 13+ Swift/SwiftUI menu-bar app.

## App Shape

- `FacePassApp`: app entry point, runtime wiring, menu-bar lifecycle
- `StatusItemController`: menu-bar icon and left/right click behavior
- `SettingsWindowController` / `SettingsView`: settings UI
- `SetupWizardWindowController`: first-run permission/setup flow
- `OverlayWindowController`: lock-screen and recognition feedback overlay

## Core Services

- `AppStateManager`: top-level orchestration and published UI state
- `PasswordVault`: Keychain-backed password storage
- `AccessibilityAutofillService`: approved macOS authorization prompt and Apple Passwords unlock prompt detection with value-only fill
- `AuthorizationPromptMonitor`: periodic unlocked-session prompt monitor
- `HotkeyManager`: default hotkey registration and dispatch
- `ScreenStateMonitor`: wake/lock-related notification bridge
- `LockScreenUnlockController`: locked-session password typing and Return path
- `ConditionManager`: automatic-action condition evaluation
- `FaceRecognitionRuntimeController`: local recognition gate orchestration
- `FaceSampleCaptureService`: short camera capture windows
- `FaceTemplateStore`: encrypted local face template storage
- `FacePassUnlockProviderPolicy`: persisted provider routing for local recognition and paired-iPhone approval across lock-screen unlock and approved unlocked-prompt fill.
- `StandByUnlockRequestVerifier`: verifies signed iPhone StandBy Unlock requests against paired-device trust, timestamp, replay, counter, Mac identity, device identity, and action.
- `StandByPairedDeviceStore`: separate Keychain-backed trust store for paired iPhone public keys and durable highest accepted counters.
- `StandByReplayCache`: request ID replay protection for signed iPhone requests.
- `StandByUnlockHTTPServer`: local HTTP and Bonjour server for `/v1/status`, `/v1/pair`, and `/v1/standby-unlock`.
- `MacDeviceIdentityStore`: local Mac identity and public-key fingerprint used for pairing and request routing.

## Runtime Flows

### Lock Screen

FacePass has two independent lock-screen providers. Users can enable local recognition unlock, iPhone StandBy Unlock, or both. The Unlock Mode settings persist one of four provider policies: local face recognition only, paired iPhone approval only, both providers, or local face recognition for lock-screen unlock plus paired iPhone approval for approved unlocked-prompt fill.

#### Local Recognition Provider

1. FacePass confirms the macOS session is locked.
2. It checks the opt-in setting and automatic-action conditions.
3. It runs local FacePass recognition.
4. If recognition passes, it reads the Keychain password.
5. It types the password and sends Return only while the session is still locked.

#### iPhone StandBy Unlock Provider

1. The user taps the companion unlock action from iPhone StandBy/Live Activity, the optional WidgetKit widget, Shortcut, or the companion app. The current widget extension exposes the Live Activity/Dynamic Island surface and an optional static widget through the same intent boundary.
2. `StandByUnlockIntent` requires local device authentication on the iPhone before any signed unlock request is sent.
3. The iPhone posts a signed `unlock_screen` request to the Mac local HTTP endpoint.
4. The Mac verifies the paired iPhone public key, request timestamp, replay cache, durable counter, iPhone device ID, Mac device ID, protocol version, request type, and action.
5. The Mac rejects expired, replayed, wrong-Mac, unpaired, disabled, provider-policy rejected, missing-password, unsupported-state, and failed local-policy cases.
6. If the Mac is locked and all Mac-side gates pass, FacePass wakes the display and uses the same locked-session password typing plus Return path.
7. If the Mac is unlocked, the selected provider policy allows iPhone prompt fill, and exactly one approved unlocked prompt field is detected, FacePass fills only the password value and does not click, submit, or press Return.

This provider does not run Mac local recognition or use the Mac camera. The iPhone never receives the Mac password, face data, or local recognition result.

### Approved Unlocked Prompts

1. FacePass confirms setup is ready and the session is unlocked.
2. It checks automatic-action conditions.
3. It detects an approved macOS authorization prompt or the narrow Apple Passwords app unlock prompt.
4. For local provider routing, it runs local FacePass recognition. For iPhone provider routing, it uses the already-verified signed paired-iPhone request.
5. If the selected provider gate passes, it reads the Keychain password.
6. It sets only the password field value.

Approved unlocked prompts are limited to administrator/System Settings authorization prompts and Apple Passwords app unlock prompts with strong Apple Passwords context. Generic LocalAuthentication prompts, ordinary app fields, and website password fields remain rejected.

It never clicks `Unlock`, submits, or presses Return for approved unlocked prompts.

### StandBy Local Protocol

StandBy Unlock uses local HTTP with QR-provided direct endpoint pairing when available and Bonjour rediscovery fallback:

- `GET /v1/status`: reports Mac device ID, protocol version, server status, public-key fingerprint, and whether iPhone unlock is enabled.
- `POST /v1/pair`: accepts a one-time pairing registration and stores the paired iPhone public key plus the registration `displayName` in the separate Keychain-backed paired-device trust store. Settings displays that stored `displayName` as the paired iPhone name.
- `POST /v1/standby-unlock`: accepts a signed request, verifies it, maps failures to non-sensitive error codes, and routes to either the Mac lock-screen provider or approved unlocked-prompt value fill according to current Mac state and Unlock Mode.

There is no external server, APNs dependency, telemetry, WebSocket transport, cloud sync, paid service, or password transfer in this protocol.

### iOS Companion

`Companion/iOS` contains the iOS companion project at `Companion/iOS/FacePassCompanion.xcodeproj`. The project defines `FacePassCompanion`, `FacePassCompanionCore`, `FacePassCompanionWidgetExtension`, and `FacePassCompanionTests` targets, with iOS deployment target 17.0 for StandBy and `LiveActivityIntent` behavior.

The app target includes QR camera scanner pairing, manual pairing JSON fallback, paired status, manual unlock request, forget pairing, and app-side Live Activity start/update. The shared core includes the Keychain-backed long-lived iPhone device ID and signing-key baseline shared by the app and extension through the configured Keychain access group from processed Info.plist and entitlement values, durable per-Mac counter with OS file lock / cross-process coordination for app and extension increments, app-group UserDefaults endpoint cache, direct QR endpoint pairing when available, short Bonjour rediscovery fallback, `/v1/pair`, and signed `/v1/standby-unlock` client. The current WidgetKit extension exposes a `FacePass Ready` Live Activity/Dynamic Island card and an `Unlock Mac` `LiveActivityIntent` button with `openAppWhenRun = false`, plus an optional static FacePass Unlock widget alongside the Live Activity without changing the signing or Mac-password boundary. The extension declares Local Network usage and `_facepass._tcp` Bonjour service access because the AppIntent can run in the extension process.

### Settings Indicators

The Password settings indicator is presence-only: it reports whether `PasswordVault` has a configured Keychain password record. It must not expose the password value, length, preview, or derived hints. Keychain availability/readiness only means the storage boundary is reachable and must not be treated as proof that a password has been saved.

The Recognition settings status is also non-sensitive. The captured-samples count is in-memory enrollment progress for the current capture sequence. After the required samples are captured, FacePass auto-saves an encrypted local template, clears the in-memory samples, and reports the saved-template result through recognition status text. The saved template remains encrypted local embedding data, not raw frames, crops, photos, or identity labels.

### Verification Status

Verification is limited: root `swift test` passes, the macOS app bundle verifies through `script/build_and_run.sh --verify`, and the iOS companion passes a generic `iphoneos` `xcodebuild build` with signing disabled, simulator tests, and signed physical-device build/install on the paired iPhone. Manual verification is still required for QR camera scanning, Local Network prompt behavior, direct QR endpoint pairing, Bonjour rediscovery against the Mac including the WidgetKit extension declarations, `/v1/pair`, `/v1/standby-unlock`, the StandBy card/AppIntent, iPhone-approved unlocked-prompt value fill, and the actual Mac lock-screen unlock path.

## Non-Goals

- No ordinary website or app password fields
- No Apple Face ID API or system biometric replacement
- No external network service, telemetry, analytics, APNs dependency, WebSocket transport, paid service, or cloud sync
- No persistent camera session

# iPhone StandBy Unlock Implementation Notes

This document holds implementation-facing details that are intentionally kept out of the README feature summary.

FacePass is still a local macOS menu-bar unlock and password-fill helper. iPhone StandBy Unlock is a paired local approval provider, not Face ID for Mac, Touch ID, a system biometric feature, or a replacement for macOS authentication.

## Scope And Safety

- Supported Mac targets remain the lock screen and approved administrator/System Settings authorization prompts only.
- Ordinary website and app password fields are not supported targets.
- Approved administrator/System Settings prompt fill is value-only. FacePass does not click `OK`, `Continue`, `Modify Settings`, `Login`, submit, or press Return for those prompts.
- Only the lock-screen path may press Return, and only after locked-session checks and provider policy pass.
- The iPhone never receives the Mac password, Mac face data, Mac camera frames, or Mac local recognition result.
- StandBy Unlock does not use an external unlock server, APNs unlock path, WebSocket transport, telemetry, cloud sync, backend account service, or paid network service.

## Feature Flow

1. The user taps the FacePass unlock action from the iPhone companion's StandBy/Live Activity surface, Dynamic Island, optional WidgetKit widget, Shortcut, or app surface.
2. `StandByUnlockIntent` requires local device authentication on the iPhone before any signed unlock request is sent.
3. The iPhone sends a signed `unlock_screen` request to the paired Mac over the local network.
4. The Mac verifies the paired public key, timestamp, replay cache, durable counter, iPhone device ID, Mac device ID, action, enabled state, provider policy, current Mac state, password configuration, permissions, and conditions.
5. If the Mac is locked and provider policy allows iPhone approval, FacePass wakes the display and uses the locked-session password typing plus Return path.
6. If the Mac is unlocked, provider policy allows iPhone prompt fill, and exactly one approved administrator/System Settings password field is detected, FacePass fills only the password value.

The MVP keeps one paired iPhone trust record at a time. Pairing a different iPhone replaces the previous paired trust record. Rejected cases include expired, replayed, stale-counter, wrong-Mac, unpaired, disabled, provider-rejected, unsupported-state, missing-password, permission-failure, and fill/unlock-failure requests.

## Local Protocol

Transport is local HTTP. The endpoint scope is limited to:

- `GET /v1/status`
- `POST /v1/pair`
- `POST /v1/standby-unlock`

The Mac prefers the fixed StandBy Unlock port `65531` and falls back only to a small bounded nearby-port range when that port is unavailable.

`GET /v1/status` reports non-sensitive Mac device and readiness metadata, including Mac device ID, protocol version, server status, public-key fingerprint, and whether iPhone unlock is enabled.

`POST /v1/pair` accepts a one-time pairing registration and stores the paired iPhone public key plus the registration `displayName` in the separate Keychain-backed paired-device trust store. Settings displays that stored `displayName` as the paired iPhone name. It is not resolved through an external account service.

`POST /v1/standby-unlock` accepts a signed request, verifies it, maps failures to non-sensitive error codes, and routes the approved action by current Mac state and Unlock Mode.

## Pairing And Rediscovery

Pairing QR codes include Bonjour metadata and, when the Mac can determine one, a LAN-reachable local HTTP endpoint. The iPhone tries direct `/v1/pair` first and falls back to Bonjour rediscovery if direct connection fails.

After pairing, the iPhone uses the cached endpoint first. If that endpoint fails, it performs short Bonjour rediscovery and can probe only a small bounded set of nearby ports on the cached host. It accepts a candidate only after `/v1/status` matches the paired Mac ID, public-key fingerprint, and ready state. It does not scan the full port range.

After pairing, Mac Settings hides the QR code and shows paired iPhone status plus Pair iPhone, Forget iPhone, and Test Connection controls.

## iOS Companion

The iOS companion project lives at `Companion/iOS/FacePassCompanion.xcodeproj` with app, shared core, WidgetKit extension, and test targets:

- `FacePassCompanion`
- `FacePassCompanionCore`
- `FacePassCompanionWidgetExtension`
- `FacePassCompanionTests`

The iOS deployment target is 17.0 for StandBy and `LiveActivityIntent` behavior.

The companion app includes QR camera pairing, manual pairing JSON fallback, paired Mac status, manual unlock request, forget pairing, and app-side Live Activity start/update. The shared core keeps a Keychain-backed long-lived iPhone device ID and signing-key baseline shared by the app and extension through the configured Keychain access group from processed Info.plist and entitlement values.

The shared core also owns durable per-Mac counters with OS file lock and cross-process coordination for app and extension increments, app-group UserDefaults endpoint cache, direct QR endpoint pairing when available, short Bonjour rediscovery fallback, `/v1/pair`, and signed `/v1/standby-unlock` client logic.

The current WidgetKit extension exposes a Live Activity/Dynamic Island `FacePass Ready` card with an `Unlock Mac` AppIntent button that does not open the app when run, plus an optional static FacePass Unlock widget using the same intent boundary. The extension declares Local Network usage and `_facepass._tcp` Bonjour service access because the AppIntent can run there.

## Verification Notes

Relevant automated checks for this area include root Swift tests, macOS app bundle verify mode, iOS companion builds with signing disabled where appropriate, iOS simulator tests, and signed physical-device build/install checks when a paired device is available.

Manual verification is still required for QR camera scanning, Local Network prompt behavior, direct QR endpoint pairing, Bonjour rediscovery against the Mac, WidgetKit extension Bonjour declarations, `/v1/pair`, `/v1/standby-unlock`, the StandBy card/AppIntent, iPhone-approved administrator/System Settings prompt value fill, and the actual Mac lock-screen unlock path.

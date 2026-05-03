# Security Model

FacePass is an unlock and password-fill helper, not a macOS authentication replacement.

## Password Storage

Passwords are stored only in macOS Keychain through `PasswordVault`.

FacePass must not store, print, log, show, or write password material to files, UserDefaults, crash reports, diagnostics, screenshots, or test output.

Password UI state is limited to whether a Keychain password record is configured and whether an explicit unlocked-session preflight read succeeded. It must not show the password value, length, preview, masked length, hash, or derived hints. Keychain availability means the storage boundary can be reached; it is not the same signal as a saved password.

iPhone StandBy Unlock does not send the Mac password to the iPhone. A valid iPhone request can ask the Mac to run the existing locked-session path, or, when Unlock Mode allows it and an approved unlocked prompt is present while the Mac is unlocked, ask the Mac to fill only the password value. Approved unlocked prompts are limited to approved administrator/System Settings prompts and the narrow Apple Passwords app unlock prompt. The Mac still reads password material only through `PasswordVault` after Mac-side policy checks pass.

## Camera

Camera access is short-lived.

FacePass starts camera capture only for explicit enrollment/observe actions or sensitive recognition gates, then stops capture after success, timeout, failure, or cancellation.

Raw camera frames, photos, crops, sample buffers, and screenshots are not persisted.

Enrollment indicators must remain non-sensitive. FacePass may show in-memory capture progress and whether an encrypted local template was saved or cleared, but it must not expose embedding values, model input images, raw sample data, face crops, or identity labels.

## Accessibility

Accessibility is used only for:

- approved macOS administrator/System Settings authorization prompt value fill
- approved Apple Passwords app unlock prompt value fill
- the separate locked-session password typing path

FacePass does not target ordinary website or app password fields.

For approved unlocked prompts, FacePass only sets the password field value. It does not click `Unlock`, confirmation buttons, press Return, submit forms, or perform mouse confirmation actions.

Generic LocalAuthentication prompts remain rejected. Apple Passwords support requires strong Apple Passwords context, not just a generic sign-in or password prompt hosted by LocalAuthentication.

## Lock-Screen Return Boundary

Only the lock-screen path may send Return.

The local recognition provider must confirm the session is locked, run local recognition, re-check safety state, read the Keychain password, type the password, and send Return only while still locked.

The independent iPhone StandBy Unlock provider may also enter the same locked-session password typing plus Return path. Before doing so, it must verify a signed paired-iPhone request, confirm FacePass and StandBy Unlock are enabled, confirm the Mac is locked, confirm the password is configured and readable through `PasswordVault`, satisfy required permissions and automatic-action conditions, wake the display, and re-check the locked-session state.

StandBy Unlock does not use the Mac camera and does not supplement or bypass the local recognition provider. Users may route approved flows through local face recognition only, paired iPhone approval only, both providers, or local face recognition for lock-screen unlock plus paired iPhone approval for approved unlocked-prompt fill.

## Recognition Boundary

FacePass uses local recognition as an app-level gate. It is not Apple Face ID and does not replace macOS authentication.

Current recognition is a usable prototype. Settings exposes an adjustable similarity threshold with the current recommended default, but stronger liveness checks, better anti-photo spoofing, and real false-accept/false-reject calibration are planned before treating it as production-grade biometric security.

## StandBy Unlock Trust Boundary

StandBy Unlock accepts only signed requests from a paired enabled iPhone. `StandByUnlockIntent` requires local device authentication on the iPhone before sending any signed unlock request. Pairing stores the iPhone public key and the registration `displayName` in a separate Keychain-backed trust store from the password vault; Settings uses that stored `displayName` as the paired iPhone display source. The current iOS companion baseline stores its long-lived iPhone device ID and P-256 signing-key material in iPhone Keychain storage. The app and extension share that iPhone signing identity through the configured Keychain access group from processed Info.plist and entitlement values.

The Mac verifies:

- paired iPhone public key
- enabled paired-device record
- supported request type, protocol version, and `unlock_screen` action
- matching Mac device ID and iPhone device ID
- timestamp, expiry, and maximum validity window
- replayed request ID
- durable monotonic counter
- local FacePass enabled state, StandBy Unlock enabled state, provider policy, lock/unlocked prompt state, Accessibility, configured password, and trusted conditions

Rejected cases include expired requests, replayed requests, stale counters, wrong Mac identity, unpaired iPhones, disabled paired iPhones, disabled provider state, provider-policy rejection, unsupported Mac state, missing passwords, permission failures, and unlock/fill failures. Error responses must remain non-sensitive and must not expose passwords or password length.

StandBy Unlock uses local HTTP for `/v1/status`, `/v1/pair`, and `/v1/standby-unlock` only. During pairing, the iOS companion tries the QR-provided local endpoint first when present and falls back to short Bonjour rediscovery if direct pairing is unreachable. After pairing, it uses a cached paired-Mac endpoint first and short Bonjour rediscovery when needed; it does not use persistent polling. It does not use external servers, APNs, WebSocket transport, telemetry, analytics, cloud sync, or a paid service.

The current WidgetKit extension exposes the Live Activity/Dynamic Island surface and an optional static FacePass Unlock widget alongside it. Both surfaces must preserve the same AppIntent, local-network, signing-key, counter, and no-Mac-password-transfer boundaries. The extension declares Local Network usage and `_facepass._tcp` Bonjour service access because the AppIntent can run in the extension process. The durable per-Mac counter uses OS file lock / cross-process coordination so app and extension increments stay monotonic across processes.

## Data Sharing

FacePass has no telemetry, analytics, cloud sync, backend account service, external unlock server, APNs unlock path, WebSocket transport, or paid network service. It does not upload passwords, face data, raw camera frames, unlock state, Wi-Fi details, display identifiers, or environment signals.

Sparkle 2 update checks are limited to the website-hosted appcast at `https://facepass.app/updates/appcast.xml` and package downloads from GitHub Releases. Sparkle is not an unlock backend, account service, telemetry channel, cloud sync path, or StandBy Unlock transport. Update checks must not upload passwords, face data, raw camera frames, unlock state, Wi-Fi details, display identifiers, or environment signals.

The iOS companion under `Companion/iOS` now has a dedicated Xcode project, app target, shared core target, WidgetKit extension target for the current Live Activity/Dynamic Island surface, test target, entitlements, Info.plist files, assets, and target wiring. Its verified status remains limited: root `swift test` passes, the macOS app bundle verifies through `script/build_and_run.sh --verify`, and the iOS companion passes a generic `iphoneos` `xcodebuild build` with signing disabled plus simulator tests.

Signed physical-device build/install on the paired iPhone has been verified. Manual verification is still required for QR camera scanning, Local Network prompt behavior, Bonjour discovery against the Mac, `/v1/pair`, `/v1/standby-unlock`, the StandBy card/AppIntent, iPhone-approved unlocked-prompt value fill, and the actual Mac lock-screen unlock path.

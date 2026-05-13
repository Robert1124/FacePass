# FacePass iOS Companion

This directory contains the local iOS companion project and source implementation for FacePass StandBy Unlock.

The dedicated Xcode project is `Companion/iOS/FacePassCompanion.xcodeproj`. It defines these targets:

- `FacePassCompanion`
- `FacePassCompanionCore`
- `FacePassCompanionWidgetExtension`
- `FacePassCompanionTests`

The iOS deployment target is 17.0 because the StandBy and `LiveActivityIntent` surfaces depend on iOS 17 behavior.

## Product Boundary

StandBy Unlock is a separate unlock provider. It is not a supplement to the Mac local face-recognition gate and does not send iPhone face state to the Mac.

The iPhone companion never receives, stores, displays, logs, or transmits the Mac password. The Mac remains responsible for checking local policy, reading its Keychain password through the macOS `PasswordVault`, typing the password, and pressing Return only through the approved locked-session path.

The iOS companion also excludes:

- APNs
- external servers
- telemetry or analytics
- WebSocket connections
- persistent polling
- Mac password transfer
- face image or face-template transfer

## Intended User Flow

1. The user opens the iOS companion and scans a FacePass pairing QR code shown by the Mac app.
2. The iPhone creates or reuses a Keychain-backed P-256 signing key.
3. The iPhone sends its public key, device identity, and display name to the Mac pairing endpoint.
4. The iPhone caches the approved Mac endpoint locally.
5. From StandBy, the FacePass Live Activity, the optional FacePass Unlock widget, a Shortcut, or the app, the user requests `unlock_screen`.
6. `StandByUnlockIntent` requires local device authentication on the iPhone before any signed unlock request is sent.
7. The iPhone signs a canonical request payload and posts it to the Mac local endpoint.
8. If the cached endpoint fails, the iPhone performs a short Bonjour rediscovery for the paired Mac, prefers the resolved numeric local address over the Bonjour hostname when available, and retries once.
9. If Bonjour rediscovery times out, the iPhone probes only a small bounded set of nearby ports on the cached host, validates `/v1/status` against the paired Mac ID and public-key fingerprint, and sends a fresh signed request only after a matching ready endpoint is found.

The current macOS workspace provides the StandBy HTTP router/server, pairing controller, and request verifier for `/v1/status`, `/v1/pair`, and `/v1/standby-unlock`.

The companion app currently includes:

- QR camera scanner pairing UI
- manual pairing JSON fallback for simulator and development use
- paired Mac status
- manual unlock request button
- forget pairing action
- app-side Live Activity start/update for the StandBy Live Activity card
- optional FacePass Unlock widget with FacePass app icon artwork, a compact FacePass label row on the small widget, and an icon-only unlock button for iOS widget/StandBy surfaces

## Pairing QR Contract

The Mac pairing QR payload uses type `facepass_standby_pairing` and includes only non-sensitive setup and discovery metadata:

- `type`
- `protocolVersion`
- `macDeviceId`
- `publicKeyFingerprint`
- `oneTimeToken`
- `bonjourServiceType` with value `_facepass._tcp`
- `bonjourDomain` with value `local`
- `expiresAt`
- optional `localEndpoint` with `host`, `port`, `scheme`, and `url` when the Mac can determine a LAN-reachable local HTTP endpoint

The QR payload must not include Mac passwords, private keys, raw public key material, unlock request IDs, or face data. Clients should try the optional local endpoint for direct `/v1/pair` first when present, then fall back to Bonjour metadata for local discovery if direct pairing is unreachable.

When the Mac includes `localEndpoint`, it should choose a LAN-reachable address from the default-route or physical network interface before virtual interfaces such as `feth`, `utun`, `bridge`, `vnic`, or `vmnet`. This keeps QR pairing from advertising a private virtual address that the iPhone cannot reach on the Wi-Fi/local network.

Pairing registration posts to `/v1/pair` with the Mac `StandByIPhonePairingRegistration` JSON shape:

- `oneTimeToken`
- `iphoneDeviceId`
- `displayName`
- `publicKeyX963Representation`

The public key field is Swift `Data` encoded with JSON base64 coding, matching the Mac `Codable` decoder expectation.

On success, the Mac validates the P-256 public key and stores the paired iPhone public-key trust record, `iphoneDeviceId`, and `displayName` in the Mac Keychain-backed `StandByPairedDeviceStore`. The iPhone never sends or receives the Mac password during pairing.

## Request Contract

Unlock requests use action `unlock_screen` and must include:

- `type`
- `protocolVersion`
- `requestId`
- `iphoneDeviceId`
- `macDeviceId`
- `action`
- `issuedAt`
- `expiresAt`
- `counter`
- `signature`

The request `type` is `standby_unlock_request` and `protocolVersion` is `1`.

The signature is P-256 over a deterministic JSON-style canonical payload with sorted keys and no `signature` field. The canonical fields are exactly `action`, `counter`, `expiresAt`, `issuedAt`, `iphoneDeviceId`, `macDeviceId`, `protocolVersion`, `requestId`, and `type`. Dates use no-fraction UTC ISO8601 formatting such as `2026-04-27T14:05:00Z`. The signing algorithm is not request-selectable.

The Mac side is expected to verify:

- paired iPhone public key
- enabled paired-device record
- request `type` is exactly `standby_unlock_request`
- request `protocolVersion` is exactly `1`
- matching `macDeviceId`
- action is exactly `unlock_screen`
- request expiry and maximum validity window
- replayed `requestId`
- stale or repeated counter
- local FacePass policy, Accessibility, password configuration, lock state, and configured automatic-action conditions

Unlock responses from `/v1/standby-unlock` decode as:

- `ok`
- `result` on success, such as `unlock_requested`
- `errorCode` when rejected

## Source Layout

- `App/FacePassCompanionApp.swift`: app entry point and root app flow.
- `App/FacePassCompanionModel.swift`: app-side state, pairing, unlock, forget-pairing, and Live Activity orchestration.
- `Features/Pairing/PairingScanView.swift`: QR pairing scan flow.
- `Features/Pairing/QRCodeScannerView.swift`: AVFoundation QR camera scanner.
- `Features/Status/PairedStatusView.swift`: paired Mac state and unlock UI.
- `Features/LiveActivity/StandByLiveActivityController.swift`: app-side Live Activity start/update.
- `Models/StandByUnlockModels.swift`: paired Mac, endpoint, pairing, and request models.
- `Services/CanonicalPayloadSigner.swift`: canonical payload generation and P-256 signing boundary.
- `Services/CompanionKeyStore.swift`: Keychain-backed long-lived iPhone device ID and P-256 signing-key baseline. The app and widget share this signing identity through the configured Keychain access group from processed Info.plist and entitlement values.
- `Services/EndpointCache.swift`: app-group UserDefaults cached paired-Mac endpoint store.
- `Services/StandByUnlockCounterStore.swift`: durable per-Mac counter in app-group UserDefaults with OS file lock / cross-process coordination for app and widget increments.
- `Services/BonjourRediscoveryService.swift`: short Bonjour rediscovery for the paired Mac.
- `Services/PairingClient.swift`: `/v1/pair` client.
- `Services/StandByUnlockClient.swift`: local HTTP request flow with cached endpoint first, Bonjour fallback, and bounded nearby-port recovery on the cached host after Bonjour timeout; fallback retries sign a fresh request with a new request ID and counter so Mac replay protection does not reject a consumed request.
- `Widgets/StandByUnlockActivityAttributes.swift`: ActivityKit attributes for StandBy/Live Activity surfaces.
- `Widgets/StandByUnlockLiveActivityWidget.swift`: `FacePass Ready` Live Activity card with an `Unlock Mac` button.
- `Widgets/StandByUnlockWidget.swift`: optional WidgetKit FacePass Unlock widget with FacePass app icon artwork, compact small-widget branding, and an icon-only unlock button using the same AppIntent as the Live Activity.
- `Intents/StandByUnlockIntent.swift`: `Request Unlock` `LiveActivityIntent` with `openAppWhenRun = false`.

The Live Activity remains the app-started StandBy card path. The optional FacePass Unlock widget is not programmatically started by the app; users add it from the iOS widget gallery or StandBy customization. Its button uses `StandByUnlockIntent`, so it usually runs the signed local request without opening FacePass, but final presentation and launch behavior can vary by iOS surface and system state.

## Verification Status

The iOS companion has moved past a non-buildable scaffold: it now has an Xcode project, app/widget/core/test targets, entitlements, Info.plist files, assets, and target wiring.

Current verified status:

- iOS core/app/widget sources pass direct iOS simulator `swiftc` typecheck.
- The iOS Xcode project uses automatic Apple Developer signing with team `WDAN6HW5VM` across the app, core framework, widget extension, and test target build configurations.
- Root `swift test` passes.
- `xcodebuild -project Companion/iOS/FacePassCompanion.xcodeproj -scheme FacePassCompanion -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO build` passes.
- `xcodebuild test -project Companion/iOS/FacePassCompanion.xcodeproj -scheme FacePassCompanion -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' CODE_SIGNING_ALLOWED=NO` passes.

Current limitations:

- Signed physical-device build/install has succeeded on the paired iPhone; keep real QR, Local Network, StandBy/AppIntent, and Mac unlock flows marked pending until those manual checks are recorded.
- The optional widget and StandBy widget placement flow still require manual verification on a supported iPhone.

Real-device manual verification is still required for:

- QR camera scanning
- Local Network prompt behavior
- Bonjour discovery against the Mac, including the widget extension's Local Network and `_facepass._tcp` Bonjour declarations because the AppIntent runs there
- `/v1/pair`
- `/v1/standby-unlock`
- StandBy card and `Request Unlock` AppIntent
- FacePass Unlock optional widget on supported iOS widget/StandBy surfaces, including whether the AppIntent runs without opening the app on the tested iOS version
- actual Mac lock-screen unlock path

## Distribution

The public distribution path for the iOS companion is the App Store: [FacePass Companion](https://apps.apple.com/app/facepass-companion/id6766098166). TestFlight is only a beta-testing channel for pre-release builds, not the main public download path. Ad Hoc builds, Apple Development signing, direct device installs from Xcode, Apple Developer Enterprise Program distribution, and sideloading are not appropriate public distribution channels for this companion. Keep those alternatives limited to development, registered-device testing, or organization-internal cases where Apple's rules allow them.

The app and widget Info.plist files set `ITSAppUsesNonExemptEncryption` to `NO`. This records that the companion uses no non-exempt encryption for App Store Connect export-compliance purposes, so new uploads should not require the recurring encryption questionnaire. If future work adds non-exempt cryptography or external encrypted transport beyond the current local signed-request, Keychain, and system-networking boundaries, revisit this value before upload.

The companion's distribution story is separate from the Mac app. Public macOS releases should use Developer ID-signed and notarized website/direct-download distribution. The iOS companion should not be documented as a workaround for distributing the Mac app, and the Mac app should remain responsible for all password access and unlock policy checks.

## App Review Notes Draft

FacePass Companion is an iPhone companion for the separately distributed FacePass macOS menu-bar helper. To test it, install the Mac helper on the same local network, open the Mac app's StandBy Unlock pairing screen, scan the QR code in the iOS app, then use the app, widget, or StandBy/Live Activity Unlock Mac action. The iPhone app stores a Keychain-backed P-256 signing key and sends signed local HTTP requests only to the paired Mac. It never receives, stores, displays, logs, or transmits the Mac password, face data, or Mac authentication result. There is no cloud server, APNs, telemetry, analytics, WebSocket, remote sync, or paid network service. The iPhone action requires local device authentication before sending a signed request; the Mac app performs all policy checks, Keychain password access, and any approved locked-session typing. FacePass is not Face ID, Touch ID, or a replacement for macOS authentication.

## App Store Connect Privacy Answers

Recommended App Privacy answer for the current iOS companion behavior: **No, this app does not collect user data**.

The companion stores pairing state locally and sends signed requests only to the paired Mac on the user's local network. The developer does not receive this data through a server, analytics pipeline, telemetry endpoint, cloud sync, APNs payload, WebSocket, or third-party service.

Do not list these as App Store Privacy Nutrition Label collection while the current local-only design remains true:

- app-generated iPhone device ID: stored in the iPhone Keychain and sent only to the paired Mac for local trust;
- paired Mac device ID, endpoint, and fingerprint: stored locally for pairing and rediscovery;
- QR scan content: processed on device for pairing;
- local network request and status text: used only between the iPhone and paired Mac;
- Mac password, Mac face data, camera frames, and recognition result: not present on the iPhone companion.

Tracking: **No**. Data linked to the user: **No data collected** under the current local-only design.

This App Store Connect answer is separate from `PrivacyInfo.xcprivacy`. The app and widget privacy manifests declare required-reason API use for app-group `UserDefaults`; they do not mean the developer collects that data.

## Security Notes

The companion keeps the iPhone role narrow: it proves possession of a paired private key and requests a lock-screen action. It does not make the iPhone an authentication database, does not hold the Mac password, and does not bypass Mac-side safety checks.

The current signing baseline is P-256 with long-lived iPhone device ID and signing-key material stored in Keychain. The app and widget extension share that signing identity only through the configured Keychain access group derived from processed Info.plist and entitlements. `StandByUnlockIntent` requires local device authentication on the iPhone before sending a signed request. The local endpoint cache and durable per-Mac counter use app-group UserDefaults, and the counter uses OS file lock / cross-process coordination so app and widget increments stay monotonic. The widget extension declares Local Network usage and `_facepass._tcp` Bonjour service access because the AppIntent can run in the widget extension process. Bonjour rediscovery is short-lived and only used for local paired-Mac discovery.

# Security Model

FacePass is an unlock and password-fill helper, not a macOS authentication replacement.

## Password Storage

Passwords are stored only in macOS Keychain through `PasswordVault`.

FacePass must not store, print, log, show, or write password material to files, UserDefaults, crash reports, diagnostics, screenshots, or test output.

## Camera

Camera access is short-lived.

FacePass starts camera capture only for explicit enrollment/observe actions or sensitive recognition gates, then stops capture after success, timeout, failure, or cancellation.

Raw camera frames, photos, crops, sample buffers, and screenshots are not persisted.

## Accessibility

Accessibility is used only for:

- approved macOS administrator/System Settings authorization prompt value fill
- the separate locked-session password typing path

FacePass does not target ordinary website or app password fields.

For administrator/System Settings prompts, FacePass only sets the password field value. It does not click confirmation buttons, press Return, submit forms, or perform mouse confirmation actions.

## Lock-Screen Return Boundary

Only the lock-screen path may send Return.

That path must confirm the session is locked, run local recognition, re-check safety state, read the Keychain password, type the password, and send Return only while still locked.

## Recognition Boundary

FacePass uses local recognition as an app-level gate. It is not Apple Face ID and does not replace macOS authentication.

Current recognition is a usable prototype. Stronger liveness checks, better anti-photo spoofing, and real false-accept/false-reject calibration are planned.

## Data Sharing

FacePass has no telemetry, analytics, cloud sync, or network service. It does not upload face data, password material, unlock state, Wi-Fi details, display identifiers, or environment values.

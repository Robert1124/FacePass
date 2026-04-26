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
- `AccessibilityAutofillService`: approved macOS authorization prompt detection and value-only fill
- `AuthorizationPromptMonitor`: periodic unlocked-session prompt monitor
- `HotkeyManager`: default hotkey registration and dispatch
- `ScreenStateMonitor`: wake/lock-related notification bridge
- `LockScreenUnlockController`: locked-session password typing and Return path
- `ConditionManager`: automatic-action condition evaluation
- `FaceRecognitionRuntimeController`: local recognition gate orchestration
- `FaceSampleCaptureService`: short camera capture windows
- `FaceTemplateStore`: encrypted local face template storage

## Runtime Flows

### Lock Screen

1. FacePass confirms the macOS session is locked.
2. It checks the opt-in setting and automatic-action conditions.
3. It runs local FacePass recognition.
4. If recognition passes, it reads the Keychain password.
5. It types the password and sends Return only while the session is still locked.

### Administrator/System Settings Prompt

1. FacePass confirms setup is ready and the session is unlocked.
2. It checks automatic-action conditions.
3. It detects an approved macOS authorization prompt.
4. It runs local FacePass recognition.
5. If recognition passes, it reads the Keychain password.
6. It sets only the password field value.

It never clicks, submits, or presses Return for administrator/System Settings prompts.

## Non-Goals

- No ordinary website or app password fields
- No Apple Face ID API or system biometric replacement
- No network service, telemetry, analytics, or cloud sync
- No persistent camera session

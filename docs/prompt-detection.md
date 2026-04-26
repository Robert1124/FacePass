# Authorization Prompt Detection

FacePass supports only approved macOS administrator/System Settings authorization prompts.

It does not support ordinary website or app password fields.

## Current Detection Rules

FacePass checks the focused Accessibility element first. If focus is missing or not on an approved secure field, it can inspect approved Apple authorization-host windows.

Approved prompt detection is intentionally narrow:

- `SecurityAgent` is allowed by Apple bundle identifier.
- System Settings/System Preferences prompts require administrator-authorization title or strong prompt-text signals.
- Modern Privacy & Security sheets may be hosted through Apple LocalAuthentication UI, but only when System Settings/Privacy & Security context and strong authorization prompt text are both present.

Generic LocalAuthentication prompts are rejected.

## Fill Behavior

For administrator/System Settings prompts, FacePass only sets the password field value.

It does not:

- click `OK`
- click `Continue`
- click `Modify Settings`
- click `Login`
- press Return
- submit the prompt
- perform mouse confirmation actions

## Duplicate Candidate Handling

Some System Settings sheets expose the same visible password field through multiple Accessibility nodes. FacePass prefers the focused secure password field when it can be safely tied to an approved System Settings authorization sheet.

Fallback discovery still fails closed when multiple distinct approved password fields remain.

Temporary diagnostics may show redacted candidate counts, role/subrole, enabled/settable state, field-text signal category, bundle/process, and hashed native ID prefixes. They must not include usernames, passwords, raw field values, prompt text, screenshots, or raw Accessibility IDs.

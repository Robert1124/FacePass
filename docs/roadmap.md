# Development Roadmap

## Current Version

The current version is a local macOS helper for:

- lock-screen assist
- approved macOS administrator/System Settings authorization prompt value fill

It is not Apple Face ID, Touch ID, or a macOS authentication replacement.

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
   - reproducible release packaging
   - Developer ID signing support
   - notarization support
   - clearer binary release instructions

## Not Planned

- ordinary website or app password-field autofill
- replacing macOS authentication
- cloud sync of face templates or passwords
- telemetry or analytics
- persistent camera monitoring

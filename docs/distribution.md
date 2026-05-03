# Distribution

FacePass remains buildable from source.

## Local Development

You can build and run locally with:

```bash
swift test
./script/setup_and_run.sh
```

The normal run prepares the ignored local model artifact when needed, builds, stages, signs the staged app ad-hoc, publishes a physical bundle to `dist/FacePass.app`, and launches it. To prepare the model and verify the app build without launching:

```bash
./script/setup_and_run.sh --verify
```

`script/setup_and_run.sh` verifies the app-bundled Core ML source artifact and, when it is missing or invalid, downloads the pinned AuraFace `glintr100.onnx`, verifies it, runs the legacy conversion path, and verifies the generated artifact under `Artifacts/Phase8/.../coreml-legacy/`. Model artifacts remain under ignored `Artifacts/` and are intentionally not committed. The app itself does not download models, and model setup does not add app network behavior beyond the documented local StandBy Unlock HTTP/Bonjour transport and Sparkle appcast/package update checks.

`--verify` must leave `dist/FacePass.app` as a real app bundle, not a symlink or shortcut. The build script signs and strictly verifies the staged app before publishing because FileProvider or iCloud-backed folders can add Finder metadata after the bundle is copied into `dist/`. The final `dist` validation checks the physical bundle shape, executable, icon, Info.plist, and compiled model resource.

When strict codesign verification also passes for `dist/FacePass.app`, that bundle is the primary verified output. If `dist/` is in a FileProvider or iCloud-backed location and strict verification fails after copy, the script does not create a symlink. It keeps the best-effort physical `dist/FacePass.app`, publishes a second physical fallback bundle to `~/Library/Caches/FacePass/dist/FacePass.app`, strictly verifies that fallback, and prints both paths. Use the cache app when strict verification matters.

The manual artifact helper remains available as an advanced fallback:

```bash
FACEPASS_PHASE8_LEGACY_PYTHON=python3.9 ./script/phase8_auraface_artifact.sh prepare-bundled
./script/build_and_run.sh --verify
```

Legacy model conversion requires Python 3.8 or 3.9. If `FACEPASS_PHASE8_LEGACY_PYTHON` is unset, the setup script tries `python3.9` and then `python3.8`.

## Without An Apple Developer Program Account

Without an Apple Developer Program account, you can:

- build from source
- run locally
- use ad-hoc signing
- use a local Apple Development certificate for your own machines
- create a DMG or development-only ZIP for testing

You cannot create a Developer ID Application certificate or notarize public direct-download software without Apple Developer Program membership.

Unsigned, ad-hoc-signed, or non-notarized apps may be blocked or warned by Gatekeeper on other Macs. For public users, source builds or properly signed/notarized releases are safer.

## Public Direct Download

The public macOS distribution path for FacePass is a Developer ID-signed and notarized DMG with Sparkle 2 update checks. FacePass is a menu-bar helper that relies on local macOS permissions and local-only helper behavior, so public macOS releases should be shipped as Developer ID/notarized Mac downloads rather than through the iOS companion's App Store/TestFlight path.

Sparkle is only an appcast and package-download channel. The configured update feed is:

```text
https://facepass.app/updates/appcast.xml
```

The website hosts `appcast.xml` under the `/updates` path. DMG release packages referenced by the appcast are hosted on GitHub Releases. This update path is not a telemetry system, backend account service, cloud sync service, APNs path, WebSocket transport, or external unlock server. Update checks must not upload passwords, face data, raw camera frames, unlock state, Wi-Fi details, display identifiers, or environment signals.

For a trusted direct-download macOS release outside the Mac App Store, Apple expects:

1. Apple Developer Program membership
2. Developer ID Application certificate
3. Hardened Runtime enabled
4. app signed with Developer ID
5. outer DMG submitted for notarization
6. notarization ticket stapled
7. Gatekeeper validation with `spctl`

Official Apple references:

- <https://developer.apple.com/support/developer-id/>
- <https://developer.apple.com/developer-id/>
- <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- <https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime>

## Release Workflow

Formal user-facing macOS releases should be produced by GitHub Actions after signing and notarization credentials are configured. The release workflow is intentionally tag-triggered:

- `v*` tags produce official release artifacts.
- `workflow_dispatch` may be used for an explicit manual release run.
- ordinary pushes must not publish user-facing releases.

Local packaging remains useful for dry-run verification, bundle inspection, signing checks, and release-candidate troubleshooting. Local ZIP archives may remain development-only dry-run artifacts, but they should not be treated as official user-facing release packages once the Actions release path is configured.

The expected official GitHub Release artifacts are `FacePass-<version>.dmg` and `FacePass-<version>.dmg.sha256`. The DMG must contain the Developer ID-signed and notarized Mac app, and the website-hosted Sparkle appcast at `/updates/appcast.xml` must reference that DMG. The release workflow is tag-triggered for `v*` tags, with explicit `workflow_dispatch` reserved for manual release runs. The current workflow writes the generated appcast back to `website/updates/appcast.xml` on the repository default branch after the release gate passes, so the site deployment must publish that path to `https://facepass.app/updates/appcast.xml`.

Required credentials and repository secrets should be documented and configured by name only, never by value. The current workflow expects:

- `FACEPASS_SPARKLE_PUBLIC_ED_KEY`
- `APPLE_TEAM_ID`
- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_ID_CERTIFICATE_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER_ID`
- `NOTARY_PRIVATE_KEY_BASE64`
- `SPARKLE_PRIVATE_ED_KEY_BASE64`

Do not commit signing certificates, private keys, notarization credentials, app-specific passwords, Sparkle private keys, generated appcast signing secrets, or release automation credentials.

## iOS Companion Distribution

The iOS companion's public distribution path should be the App Store, with TestFlight used for public or invited beta testing before release. The companion must preserve the current product boundary: local signed requests only, no Mac password transfer to the iPhone, no face data transfer, no cloud service, no APNs, no telemetry, and no claim that FacePass replaces Face ID, Touch ID, or macOS authentication.

Ad Hoc builds, local Apple Development signing, direct device installs from Xcode, Apple Developer Enterprise Program distribution, and sideloading are not appropriate public distribution channels for the FacePass iOS companion. They may be useful only for local development, limited registered-device testing, or organization-internal deployment where Apple's rules allow them; they should not be documented as the public release plan.

Official Apple references:

- <https://developer.apple.com/distribute/>
- <https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/set-distribution-methods/>
- <https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/>
- <https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile>
- <https://developer.apple.com/programs/enterprise/>

## Current Signing State

The repository does not include signing certificates, provisioning profiles, private keys, or notarization credentials.

Do not commit:

- `.p12`
- `.cer`
- signing requests
- provisioning profiles
- notarization credentials
- app-specific passwords
- private keys
- Sparkle private keys
- generated appcast signing secrets

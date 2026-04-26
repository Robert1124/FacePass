# Distribution

FacePass is currently source-first.

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

`script/setup_and_run.sh` verifies the app-bundled Core ML source artifact and, when it is missing or invalid, downloads the pinned AuraFace `glintr100.onnx`, verifies it, runs the legacy conversion path, and verifies the generated artifact under `Artifacts/Phase8/.../coreml-legacy/`. Model artifacts remain under ignored `Artifacts/` and are intentionally not committed. The app itself does not download models or add network behavior.

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
- create a DMG or ZIP for testing

You cannot create a Developer ID Application certificate or notarize public direct-download software without Apple Developer Program membership.

Unsigned, ad-hoc-signed, or non-notarized apps may be blocked or warned by Gatekeeper on other Macs. For public users, source builds or properly signed/notarized releases are safer.

## Public Direct Download

For a trusted direct-download macOS release outside the Mac App Store, Apple expects:

1. Apple Developer Program membership
2. Developer ID Application certificate
3. Hardened Runtime enabled
4. app signed with Developer ID
5. outer ZIP/DMG/PKG submitted for notarization
6. notarization ticket stapled
7. Gatekeeper validation with `spctl`

Official Apple references:

- <https://developer.apple.com/support/developer-id/>
- <https://developer.apple.com/developer-id/>
- <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- <https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime>

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

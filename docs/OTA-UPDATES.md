# SuperNotch OTA Updates

SuperNotch uses Sparkle 2 for in-app over-the-air updates.

## Runtime flow

1. SuperNotch reads `appcast.xml` from the latest GitHub Release.
2. Sparkle compares the appcast version with the installed bundle.
3. The user can review release notes and choose **Install and Relaunch**.
4. Sparkle downloads `SuperNotch.dmg` inside the updater flow.
5. The archive is verified with the SuperNotch EdDSA public key embedded in `Info.plist`.
6. Sparkle installs the update and relaunches SuperNotch.

The updater does not require an Apple Developer Program membership. Developer ID signing and notarization can be added later to improve Gatekeeper behavior, while Sparkle's EdDSA signature protects the update archive itself.

## Signing key

The public key embedded in `SuperNotch/Info.plist` is:

```text
aF0KDVSWqVix//Hji7UKns4dLcBYlZkn7ZMrrnzCEcY=
```

The matching private key must never be committed to this repository.

Create this repository Actions secret:

```text
SPARKLE_PRIVATE_KEY
```

Set its value to the base64 private seed generated for SuperNotch. Keep an offline backup. Losing this key means existing unsigned SuperNotch installations cannot verify updates signed by a replacement key without an explicit migration path.

## Release pipeline

The normal `macOS Release` workflow publishes `SuperNotch.dmg`.

After the GitHub Release is published, `.github/workflows/sparkle-ota.yml` automatically:

- downloads the published DMG,
- reads `CFBundleShortVersionString` and `CFBundleVersion` from the bundled app,
- verifies the tag matches the app version,
- signs the DMG with Sparkle EdDSA,
- builds `release-notes.html`,
- builds `appcast.xml`, and
- uploads both files to the same GitHub Release.

The stable feed URL used by installed applications is:

```text
https://github.com/budimanr3101/supernotch/releases/latest/download/appcast.xml
```

Every public release intended for OTA distribution must therefore contain these assets:

```text
SuperNotch.dmg
SuperNotch.dmg.sha256
appcast.xml
release-notes.html
```

## Manual recovery

If the automatic OTA metadata job fails after a release is published, fix the issue and run **Sparkle OTA Feed** manually with the existing release tag. The workflow uses `--clobber`, so it can safely replace only `appcast.xml` and `release-notes.html` without replacing the application DMG.

## Safety rules

- Never commit or print `SPARKLE_PRIVATE_KEY` in workflow logs.
- Do not change `SUPublicEDKey` after shipping it unless a planned key rotation has been implemented.
- Do not publish an appcast whose version does not match the version inside `SuperNotch.app`.
- Keep the normal DMG checksum even though Sparkle separately verifies the update using EdDSA.
- CI compilation is not a substitute for testing Install and Relaunch on a real Mac.

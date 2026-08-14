# Release checklist

Use this checklist for every public build. The canonical application identifier
on Android, iOS, macOS, and Linux is `com.cmsflash.gameoflife`.

## Product inputs

- [ ] Choose the public HTTPS API origin and pass it as
  `--dart-define=API_BASE_URL=https://…`; never ship the localhost default.
- [ ] Confirm the release version and monotonically increasing build number in
  `apps/game_app/pubspec.yaml`.
- [ ] Allowlist the production web callback and
  `com.cmsflash.gameoflife://auth` in the backend and identity provider.
- [ ] Finalize store descriptions, screenshots, age rating, and
  account-deletion instructions. Use the operator's public support page at
  `https://cmsflash.github.io/contact/`.
- [ ] Complete the Apple privacy answers and Google Play Data safety form
  against the behavior of the release candidate.
- [ ] If turn notifications are enabled, verify the deployed push mode and
  public VAPID key, provider credentials, iOS Push Notifications capability,
  APNs/Firebase configuration, and browser service-worker scope.

## Signing and builds

- [ ] Android: provide the production upload key through
  `android/key.properties` or the `ANDROID_KEYSTORE_PATH`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and
  `ANDROID_KEY_PASSWORD` environment variables.
- [ ] Android: run
  `flutter build appbundle --release --dart-define=API_BASE_URL=https://…` and
  verify the AAB certificate and package name before upload.
- [ ] iOS: select the publishing team and App Store provisioning profile, then
  run `flutter build ipa --release --dart-define=API_BASE_URL=https://…`.
- [ ] macOS: configure Developer ID or Mac App Store signing as appropriate,
  build with `flutter build macos --release`, and notarize non-store builds.
- [ ] Windows: sign `GameOfLife.exe` and its installer with the publisher's
  code-signing certificate.
- [ ] Linux: package the release bundle together with its included desktop file
  and icon; verify the package on a clean supported distribution.
- [ ] Web: build with `flutter build web --release --no-web-resources-cdn` and
  confirm the host serves `index.html` for application routes.

## Release-candidate verification

- [ ] Require all CI jobs to pass, including Android, web, Linux, macOS,
  unsigned iOS, and Windows release compilation.
- [ ] Install each signed artifact on a clean device and smoke-test account
  creation, sign-in, password recovery, local play, online play, deep-link
  return, logout, and account deletion.
- [ ] On every enabled push platform, verify one immediate turn alert, alert
  navigation to the exact match, subscription removal on sign-out/account
  deletion, and stale-reminder suppression after the turn changes.
- [ ] Confirm Android backup and device transfer do not restore
  `FlutterSecureStorage.xml`.
- [ ] Confirm production traffic uses HTTPS and no build contains test signing
  keys, localhost API URLs, secrets, debug entitlements, or debug symbols not
  intended for symbolication.
- [ ] Archive immutable artifacts, checksums, symbols, source revision, release
  notes, and signing provenance before uploading to any store or host.

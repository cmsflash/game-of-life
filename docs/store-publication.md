# Store publication checklist

The repository can produce release builds, but a release is not ready to
submit until the operator supplies the values and evidence below. Do not use
placeholders in a store record.

## Product record

- Product name: **The Game of Life**
- Version: **1.0.0**
- Category: **Games / Strategy**
- Short description: **Conway’s rules become a competitive two-player strategy
  game. Place one cell, evolve the board, and outlive your opponent.**
- Publisher/operator identity: **Shen Zhuoran / CMSFlash**
- Public support URL: **https://cmsflash.github.io/contact/**
- A public Privacy Policy URL, normally the hosted app's `/privacy` route
- An external account-deletion URL, normally the hosted app's
  `/account-deletion` route

## Release configuration

- Build with a real HTTPS API:
  `--dart-define=API_BASE_URL=https://API_HOST`
- Enable Google login only when the backend provider is configured:
  `--dart-define=GOOGLE_SIGN_IN_ENABLED=true`
- Keep Google login disabled on Apple platforms unless a compliant equivalent
  login is added.
- Confirm the immutable application identifier is
  `com.cmsflash.gameoflife` on each store.
- Supply the Android upload keystore through `android/key.properties`.
- Select the Apple development team, distribution certificate, provisioning
  profiles, App Store Connect record, and export options outside source
  control.
- Register and verify the native authentication callback scheme
  `com.cmsflash.gameoflife://auth`.

## Review package

- Phone and tablet screenshots showing home, local setup, a live match, online
  lobby, profile, privacy policy, and account deletion.
- Android feature graphic and final adaptive-icon preview.
- Review notes explaining that local play needs no account and how reviewers
  can exercise online play with two test accounts.
- A disposable reviewer account when the store review process permits one.
- Completed Apple privacy nutrition labels and Google Play Data Safety form
  consistent with [`privacy-policy.md`](privacy-policy.md).
- Age rating answers reflecting online interaction without opponent-authored
  text or names.

## Verification

Run the repository's formatting, analysis, unit, integration, and
infrastructure validation. Then build the exact candidate artifacts:

```bash
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://API_HOST
flutter build ipa --release \
  --dart-define=API_BASE_URL=https://API_HOST
flutter build macos --release \
  --dart-define=API_BASE_URL=https://API_HOST
flutter build web --release --no-web-resources-cdn \
  --dart-define=API_BASE_URL=https://API_HOST
```

Install each candidate on a clean device, create and delete an account, play
one complete local match, complete one two-account online move, test password
recovery, and verify policy links before submission.

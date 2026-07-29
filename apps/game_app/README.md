# The Game of Life — Flutter client

The cross-platform client for the competitive Game of Life. It runs on Android,
iOS, web, macOS, Windows, and Linux and uses the shared pure-Dart
`game_engine` package for offline matches.

## Included flows

- Responsive Material 3 landing page and navigation
- Offline hot-seat play on a 20×20 board
- Elimination, turn-limit, and population-target victory modes
- Username/email/password registration, confirmation, login, recovery, reset,
  player profile, secure token persistence, refresh, and logout
- Optional Google browser sign-in using a one-time backend exchange code
- In-app privacy, Terms, open-source license, and permanent account deletion
- Quick matchmaking, private match creation, join by code, match list, online
  board polling, move submission, stale-revision recovery, and resignation
- Server board decoding for the canonical state JSON and packed 2-bit format

Username/password authentication never contacts Google and remains available
when Google is unreachable.

## Run

```sh
flutter pub get
flutter run \
  --dart-define=API_BASE_URL=http://localhost:8080

# Web with the backend's default local Google return URL:
flutter run -d chrome --web-port=3000 \
  --dart-define=API_BASE_URL=http://localhost:8080
```

For an Android emulator use
`--dart-define=API_BASE_URL=http://10.0.2.2:8080`. Cleartext traffic is enabled
only in the Android debug manifest; release deployments must use HTTPS.

`API_BASE_URL` defaults to `http://localhost:8080` for development. A release
build refuses to start unless the value was explicitly set to a non-local HTTPS
origin. `GOOGLE_RETURN_URI` is optional:
web defaults to the current origin plus `/auth/callback`; native apps default to
`com.cmsflash.gameoflife://auth`. Every return URL must be allowlisted by the
backend.

Google sign-in is disabled in release builds unless
`--dart-define=GOOGLE_SIGN_IN_ENABLED=true` is provided. It is deliberately
hidden on iOS and macOS until a qualifying equivalent login provider is
implemented. Username/password login remains available everywhere.

The web build uses path URLs. Configure the production web host to serve
`index.html` for unknown application routes, including `/auth/callback`, so a
Google redirect can bootstrap Flutter before the router consumes its one-time
code.

Android, iOS, and macOS register the reverse-domain callback scheme. Windows
and Linux builds gracefully direct players to password login until their
installers register a callback protocol.

For a Play Store bundle, copy `android/key.properties.example` to
`android/key.properties`, point it at the private upload keystore, and replace
the placeholder values. The real properties file and keystores are ignored by
Git. Android release tasks fail when that file is absent or incomplete, so a
debug-signed artifact cannot be mistaken for a store candidate.

The web routes `/privacy`, `/terms`, and `/account-deletion` are the canonical
public policy surfaces when this app is hosted. Final store records still need
the operator's real support contact and publisher identity; see
[`../../docs/store-publication.md`](../../docs/store-publication.md).

## Verify

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn \
  --dart-define=API_BASE_URL=https://api.example.com
```

The API repository accepts the shared error envelope
`{error: {code, message, details?, requestId?}}`. Online games remain
server-authoritative: the client submits a coordinate and expected revision,
then renders the state returned by the API.

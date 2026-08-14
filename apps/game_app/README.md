# The Game of Life — Flutter client

The cross-platform client for the competitive Game of Life. It runs on Android,
iOS, web, macOS, Windows, and Linux and uses the shared pure-Dart
`game_engine` package for offline matches.

The iOS app requires iOS 15.0 or later, matching the minimum supported by its
Firebase Core and Messaging dependencies.

## Included flows

- Responsive Material 3 Home/Player navigation with one unified game list
- Multiple persistent offline hot-seat games on a 20×20 board
- Two-step move previews with same-cell confirmation and accessible controls
- Elimination, turn-limit, and population-target victory modes
- Username/email/password registration, confirmation, login, recovery, reset,
  player profile, secure token persistence, refresh, and logout
- Optional Google browser sign-in using a one-time backend exchange code
- In-app privacy, Terms, open-source license, and permanent account deletion
- Quick matchmaking, public/private room creation, join by code, match list, online
  board polling, move submission, stale-revision recovery, and resignation
- Opt-in turn alerts on web, Android, and iOS with direct links back to a match
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

## Turn notifications

Notification support is provider-neutral at the application/API boundary. Web
uses the standard Web Push protocol, while Android and iOS use Firebase Cloud
Messaging. Builds without notification configuration remain valid; the Player
screen explains that notifications are unavailable instead of prompting the
player.

Web builds load the public VAPID key from `GET /v1/notifications/config`. This
keeps the key used for browser subscriptions paired with the backend's private
key. Keep the VAPID private key only in the backend's secret store. Web Push
requires HTTPS except on localhost. The client registers
`push-service-worker.js` under the narrow `/push/` scope so it does not replace
Flutter's application service worker. Production hosting should serve that
stable script with `Cache-Control: no-cache`.

Native builds initialize Firebase from build-time values, so no
`google-services.json` or `GoogleService-Info.plist` is checked in:

```sh
# Shared values
--dart-define=FIREBASE_PROJECT_ID=PROJECT_ID
--dart-define=FIREBASE_MESSAGING_SENDER_ID=SENDER_ID

# Android
--dart-define=FIREBASE_ANDROID_API_KEY=ANDROID_API_KEY
--dart-define=FIREBASE_ANDROID_APP_ID=ANDROID_APP_ID

# iOS
--dart-define=FIREBASE_IOS_API_KEY=IOS_API_KEY
--dart-define=FIREBASE_IOS_APP_ID=IOS_APP_ID
--dart-define=FIREBASE_IOS_BUNDLE_ID=com.cmsflash.gameoflife
```

`FIREBASE_API_KEY` and `FIREBASE_APP_ID` can replace the platform-specific
values when a build targets only one native platform. These identifiers are
not server credentials. FCM service-account credentials and the Apple APNs
authentication key remain backend/Firebase secrets. Before distributing iOS,
enable Push Notifications for the App ID and provisioning profile and upload
an APNs authentication key to Firebase. Android 13+ and iOS ask the player for
permission only after they turn the Player preference on.

The authenticated client contract is:

- `GET /v1/notifications/config` is public and returns enabled providers plus
  the public Web Push key
- `GET /v1/notifications/subscriptions`
- `POST /v1/notifications/subscriptions` to upsert the current installation
- `DELETE /v1/notifications/subscriptions/{installationId}`

The server sends an immediate turn alert and reminders after 8, 24, and 72
hours while the same turn remains pending. Both Web Push and FCM payloads should
include `data.matchId` (or `data.path`) so tapping an alert opens
`/online/match/{id}`. Web notification payloads may additionally include a
`notification` object with `title` and `body`.

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

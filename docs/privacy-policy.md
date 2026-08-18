# Privacy Policy

Effective August 14, 2026.

This policy describes how The Game of Life processes information when a player
uses the local game or the optional online service.

## Local play

Local matches run on the player's device. They do not require an account and
are not sent to the online service. Match positions and the local player names
entered for them are saved on that device so games can be resumed; they can be
removed from the game's menu or by clearing the application's local data. The
current application contains no advertising or third-party analytics.

## Information processed for online play

An online account includes a username, display name, email address,
verification state, internal account identifier, and authentication tokens.
Password handling is delegated to the configured identity provider; the game
service does not store plaintext passwords. Google account data is processed
only when optional Google sign-in is enabled and the player chooses it.

The online service stores match rules, board states, moves, results, internal
player identifiers, public display-name snapshots, Elo ratings, games/wins/
losses/draws, kill totals, friend relationships and requests, pending friend
challenges, short-lived matchmaking records, and—when uploaded—a processed
profile picture. A player's chosen display name and current profile picture are
shown to other players; the display name is retained with match history, while
matches do not store picture URLs. Login usernames and email addresses are not
included in match or Social documents.

Kill totals update during active games after each accepted rated move. Elo,
wins, losses, draws, and total-game counts update when a rated match ends. Local
games do not contribute to online statistics.

Every active account appears in player search during this development phase.
Other signed-in players can find it by a case-insensitive public-display-name
prefix and see only its public display name, opaque player ID, rating, and current
profile-picture reference. There is currently no search-privacy preference.

Profile-picture upload accepts a JPEG, PNG, or WebP of up to 3 MiB. The service
validates and decodes it under strict dimension limits, applies orientation and a
square crop, and stores only a metadata-stripped 512×512 WebP in a private object
bucket; the source file is not retained. The versioned delivery route is public so
the picture can render in shared match and Social interfaces. A previous version
stops resolving as soon as the authoritative profile changes, although a browser
or shared cache may retain already-fetched bytes for up to 60 seconds.

If a player grants browser or operating-system notification permission, the signed-
in application automatically registers or refreshes a random
installation identifier and either a browser push endpoint with its
browser-generated encryption material or a mobile push registration token. It
may also store the device locale, time zone, and platform category. These
values are used only to deliver and troubleshoot requested game notifications;
push credentials are not returned by the account API or shown to opponents.
Players disable delivery in browser/system settings; sign-out and account deletion
remove the server registration and deactivate it locally.

Security and reliability logs may include request time, route, status, request
identifier, source IP address, response size, and platform category. Request
bodies, access tokens, refresh tokens, passwords, confirmation codes, and OAuth
exchange codes are not intentionally logged.

## Purposes and sharing

Information is used to provide accounts, recovery, matchmaking, online play,
friends, challenges, ratings, replays, turn notifications, abuse prevention,
security, and service operations. Public display names are disclosed to matched
opponents, friends, request/challenge participants, and signed-in searchers.
Current profile pictures are available through their public versioned delivery
URLs. Other information is disclosed only
to infrastructure and identity providers needed for those functions, or when
legally required. It is not sold and is not used for targeted advertising.

## Retention and deletion

- Account information is kept while the account exists.
- Waiting matchmaking entries expire after about 10 minutes and result entries
  after about one hour. A waiting candidate includes the public display-name
  snapshot used to form a match.
- One-time login exchanges expire after about five minutes; the backing
  records are eligible for automatic removal.
- Command-deduplication records expire after about 24 hours.
- Pending friend challenges become unusable after seven days. DynamoDB removes
  their canonical and projection rows asynchronously, and the service reconciles
  partial TTL cleanup on later Social access. Accepted-result pointers also expire
  after about seven days; completed matches follow match-history retention.
- Push subscriptions remain until the installation unregisters, the provider
  reports them expired, or the account is deleted. Delivery-deduplication rows
  expire after about seven days. New reminder schedules contain no player ID and
  derive their recipient from the match when invoked. A raw-ID rolling-deployment
  deletion guard expires after about one day. A separate durable account-state
  tombstone, keyed only by a SHA-256 digest of the former random account ID, is
  retained to prevent a failed or retried identity deletion from recreating data.
  During the notification rollout, reminder jobs created by the previous version
  may retain a raw recipient ID until their scheduled run and automatic deletion,
  no more than about 72 hours. They recheck the deleted account and authoritative
  match state and cannot deliver after deletion.
- Every processed picture object receives a delayed cleanup check before its
  profile pointer can be published. New objects remain `pending`; the worker
  promotes the exact current pointer to `active` and deletes anything else.
  Queue and dead-letter records contain only a SHA-256 owner digest
  and hashed-prefix object key, never the raw account ID, and can remain encrypted
  for up to 14 days. Replaced, removed, failed, or unpublished objects are deleted
  immediately when possible; retry plus an approximately one-day pending/orphan
  lifecycle backstop covers ordinary failures. Cleanup alarms require operator
  investigation if a rare cross-store race or repeated provider failure persists.
  Account deletion immediately fences the public profile,
  picture pointer, and delivery route and makes a best-effort synchronous pass
  over the private object prefix. An upload that began before that fence can finish
  a private write after the empty-prefix pass; it never becomes publicly readable,
  is checked by the durable cleanup worker after about 15 minutes, and remains
  covered by the approximately one-day pending/orphan lifecycle if immediate or
  queued deletion fails.
- Operational logs use a 30-day default retention.
- DynamoDB point-in-time recovery can retain deleted table data for up to 35
  days before it ages out.

A signed-in player can permanently delete an account from **Settings → Delete
account**. Deletion removes the identity account and recovery email, cancels
waiting matches, treats active matches as resignations, removes player/search/
Social/stats records, profile pictures, and push subscriptions, and anonymizes stored display names
and move identifiers in retained match history. Result ledgers keep only match-
level scores, kill counts, rating transitions, and ordering—not player IDs.
Limited operational logs and encrypted
backups age out under the periods above. Encrypted DynamoDB stream copies of
recently changed records expire after about 24 hours; only match changes pass
the notification consumer's invocation filter.

The hosted web application must expose `/account-deletion` as the external
account-deletion information page required by app stores.

## Player choices and contact

Players can use local play without an account, decline optional Google
sign-in, sign out to remove the local session, or delete the account. The
service operator is **Shen Zhuoran / CMSFlash**. For support or privacy
requests that cannot be completed in the app, use the public
[support page](https://cmsflash.github.io/contact/).

# HTTP API v1

The Flutter application uses one JSON API rooted at `/v1`. Except for health,
registration, login, password recovery, Google callbacks, notification config,
and versioned profile-picture delivery, endpoints require
`Authorization: Bearer <access token>`.

Errors always use this envelope:

```json
{
  "error": {
    "code": "stableMachineCode",
    "message": "Human-readable explanation.",
    "details": {},
    "requestId": "trace-id"
  }
}
```

Unknown request fields are rejected. Passwords are 10–256 characters and must
contain a letter and a number. Usernames are 3–32 ASCII letters, numbers,
periods, underscores, or hyphens.

## Accounts

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/auth/register` | Register `{username,email,password,displayName}`. |
| `POST` | `/auth/confirm` | Confirm `{username,code}`. |
| `POST` | `/auth/resend` | Resend confirmation for `{username}`. |
| `POST` | `/auth/login` | Exchange `{username,password}` for a token set. |
| `POST` | `/auth/refresh` | Refresh with `{refreshToken}`. |
| `POST` | `/auth/forgot` | Request reset mail for `{username}`. |
| `POST` | `/auth/reset` | Reset with `{username,code,newPassword}`. |
| `POST` | `/auth/logout` | Revoke the bearer token. |
| `GET` | `/auth/google/start?returnTo=…` | Begin Google/Cognito authorization. |
| `GET` | `/auth/google/callback` | Cognito callback; redirects to the app. |
| `POST` | `/auth/exchange` | Redeem a one-time `{code}` for a token set. |
| `GET` | `/me` | Return the authenticated player profile. |
| `POST` | `/me/avatar` | Upload multipart field `file`; return `{avatarUrl,avatarVersion}`. |
| `DELETE` | `/me/avatar` | Remove the current picture; return `{avatarUrl:null,avatarVersion}`. |
| `DELETE` | `/me` | Permanently delete the authenticated account; returns `204`. |

The Google flow uses authorization code plus S256 PKCE, signed state, an exact
return-URL allowlist, and two atomic one-time records. Google is optional;
password authentication never contacts it. Local mode uses the same app
callback and exchange shape with an explicitly marked development account.

Account deletion first cancels waiting games and matchmaking requests and
resigns every active game. Completed game records remain available to the
opponent, but the deleted player's identifier and stored display name are
replaced with an unlinkable `Deleted player` identity in both match state and
move history. Friend relationships, requests, pending challenges, searchable
profile, stats record, memberships, matchmaking records, idempotency records,
push subscriptions, and identity-provider account are then removed. Rating
ledgers contain match aggregates but no player IDs. Existing access and refresh
tokens no longer authenticate.

## Players, friends, challenges, and stats

Except for exact-version picture delivery, all routes below require authentication.
Every active account is publicly discoverable during this development phase. The
server applies NFKC normalization, case folding, and whitespace normalization and
matches a 1–48-character query against every substring of the public display name
and, for native accounts, the login username. It returns at most 20 matches and
omits the caller. Email addresses and Google/provider-generated login
identifiers are neither searchable nor returned.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/players/search?q=…` | Return public active-player summaries. |
| `GET` | `/players/{playerId}/avatar?v=N` | Publicly return the exact current processed WebP or `404`. |
| `GET` | `/social` | Coherent `{version,discoverable:true,friends,incomingFriendRequests,outgoingFriendRequests,incomingChallenges,outgoingChallenges}` snapshot. |
| `PATCH` | `/social/discoverability` | Rolling-client compatibility only; always returns `discoverable:true`. |
| `GET` | `/friends` | List accepted friends. |
| `POST` | `/friends/requests` | Send `{playerId}`; returns the stable request document. |
| `POST` | `/friends/requests/{id}/accept` | Recipient accepts; returns `204`. |
| `DELETE` | `/friends/requests/{id}` | Recipient declines or sender cancels; returns `204`. |
| `DELETE` | `/friends/{playerId}` | Either participant removes the friendship; returns `204`. |
| `GET` | `/challenges` | List incoming and outgoing pending friend challenges. |
| `POST` | `/challenges` | Challenge a current friend with `{opponentId}`. |
| `POST` | `/challenges/{id}/accept` | Invited friend accepts; returns `{matchId}`. |
| `DELETE` | `/challenges/{id}` | Invited friend declines or challenger cancels; returns `204`. |
| `GET` | `/stats/me` | Return `{rating,games,wins,losses,draws,kills,spawns}`; `kills` and `spawns` include current rated games. |

Public player summaries are
`{id,displayName,username,rating,avatarUrl,avatarVersion}`. `username` is the
native login username or `null` for an account without a public native handle;
clients render a non-null value with a leading `@`. `avatarUrl` is nullable and
includes its version query. Search, Social, friend, request, and challenge
documents use this same public summary. Friendship is one canonical unordered
pair, so crossed or retried requests cannot create duplicate edges. The target
must still be active when a new request commits. Accounts are limited to 100
friends, 100 pending requests, and 20 pending challenges.

Profile-picture upload accepts JPEG, PNG, or WebP transport up to 3 MiB. Before
reading or decoding, the server enforces a per-account limit of ten upload attempts
per hour. It verifies the declared and detected type, rejects animation/multiple
pages, decompression bombs, SVG, invalid images, dimensions above 4096 per side or
16 megapixels, applies EXIF orientation, center-crops, and re-encodes one 512×512
WebP without source metadata. Originals are never stored. Successful delivery is
cacheable for at most 60 seconds with revalidation; a stale version returns `404`.
Uploaders must have the right to use the picture and must not submit unlawful,
abusive, or infringing content; the service may reject or remove such content.

A challenge document is `{id,challenger,opponent,createdAt,expiresAt}`. It is
available only to its two participants, expires functionally after seven days,
and does not appear as a waiting room or expose a join code. Acceptance rechecks
the friendship and creates exactly one randomly colored active match. Retrying a
successful acceptance returns the same `matchId`, including after a lost response.
Expired storage is removed asynchronously by DynamoDB TTL and is also reconciled
on the next Social access; account deletion removes it immediately.

Every authenticated remote match—private room, quick match, or accepted friend
challenge—is rated. Local device games are never uploaded, globally scored, or
rated. Ratings start at 1200 and use standard Elo with K=32, unbounded signed
integers, symmetric half-away-from-zero rounding, and one zero-sum transfer.
Terminal moves and resignations update both players' rating and counters exactly
once in the same transaction as the result ledger and the separate spawn-result
record. The `kills` response combines finalized counters with the authenticated
player's authoritative cumulative kills in every active rated match. A Black-cell
death credits White and a White-cell death credits Black on either player's turn.
The `spawns` response similarly counts every evolution birth of that player's color
on either player's turn; the manually placed cell is not a spawn. Both totals are
visible after each accepted move. Active histories are read through their
snapshotted revision. Completed matches written before spawn-result records existed
are reconstructed from contiguous move history until the atomic migration adds the
durable totals and result record.

## Turn notifications

`GET /notifications/config` is public and returns the configured provider names
plus the public VAPID key when standard Web Push is enabled. Registration and
deletion require a bearer token and are always scoped to that account.

| ID | Method | Path | Purpose |
| --- | --- | --- | --- |
| N1 | `GET` | `/notifications/config` | Read enabled providers and the public Web Push key. |
| N2 | `POST` | `/notifications/subscriptions` | Create or replace one authenticated installation subscription. |
| N3 | `GET` | `/notifications/subscriptions` | List token-free subscription metadata for this account. |
| N4 | `DELETE` | `/notifications/subscriptions/{installationId}` | Remove this account's installation subscription; returns `204`. |

Browser registration uses standard Web Push:

```json
{
  "installationId": "client-generated-stable-random-id",
  "platform": "web",
  "provider": "webPush",
  "endpoint": "https://fcm.googleapis.com/fcm/send/browser-subscription",
  "p256dh": "browser-generated-public-key",
  "auth": "browser-generated-auth-secret",
  "locale": "en-US",
  "timeZone": "America/Los_Angeles"
}
```

Android and iOS registration uses a Firebase registration token:

```json
{
  "installationId": "client-generated-stable-random-id",
  "platform": "android",
  "provider": "firebase",
  "token": "firebase-registration-token",
  "locale": "en-US",
  "timeZone": "America/Los_Angeles"
}
```

The response and list endpoint never return the endpoint, token, encryption
keys, or auth secret. Registering the same installation under a new account
atomically removes its old account association. After a player grants browser/
OS permission and signs in, the client automatically registers or refreshes the
installation; delivery is disabled through browser/system settings rather than a
separate account preference. Sign-out and account deletion unregister it. The
server sends at turn start and after 8, 24, and 72 hours. Scheduled payloads
contain only match ID, revision, turn-start time, and reminder offset; the worker
derives the current recipient from the authoritative match. Native usernames,
email addresses, and provider-generated login identifiers never enter a
notification document or provider payload. Every delivery
rechecks status, revision, account state, and player-to-move, so stale jobs send
nothing.
Each account can keep up to five active installations.

## Matches

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/matches` | Create a waiting private match. |
| `POST` | `/matches/join` | Join `{joinCode}` and activate the match. |
| `GET` | `/matches` | List every match associated with the authenticated account, newest first. |
| `GET` | `/matches/{id}` | Read one match; supports `If-None-Match`. |
| `DELETE` | `/matches/{id}` | Creator cancels a waiting match. |
| `POST` | `/matches/{id}/moves` | Place a cell and evolve once. |
| `POST` | `/matches/{id}/resign` | Resign an active match. |
| `GET` | `/matches/{id}/moves` | Read its append-only move events. |
| `GET` | `/matches/{id}/replay` | Reproduce and return the canonical replay. |

Match path IDs use canonical 36-character UUID syntax. Other values are
rejected before a repository lookup.
Stored player summaries contain each participant's public `displayName`,
snapshotted when the match is formed and associated with the randomly assigned
color. Responses hydrate the current `avatarUrl` and `avatarVersion` in a bounded
batch; stored matches never persist expiring or superseded picture URLs.
Native login usernames, email addresses, and provider-generated login
identifiers are never included in match documents. Accepting a friend challenge
does not copy its public `username` handle into the resulting match.
Deleting an account replaces that participant's stored name and identifier
with an unlinkable `Deleted player` identity in retained history.

Move body:

```json
{
  "row": 4,
  "column": 11,
  "expectedRevision": 8,
  "idempotencyKey": "a-client-generated-unique-value"
}
```

Resignation has `expectedRevision` and `idempotencyKey`. Idempotency records
include a request fingerprint: reusing a key for different content returns
`409 idempotencyConflict`. The engine revision advances only for cell moves;
the separate match `version` advances for every mutation and is used by DynamoDB
conditional writes. Response ETags also include the current presence/version of
both players' hydrated profile pictures, so changing a picture invalidates an
otherwise unchanged match response.

Match documents include an optional `lastMove` object with `revision`,
`player`, `row`, and `column`. It is written atomically with a successful move
and remains present if that placed cell dies during the resulting evolution.
They also expose `origin` (`private`, `quick`, or `friendChallenge`), `rated`, and
`completedAt` for terminal matches. Pending friend challenges remain separate
Social records and never appear in `/matches` until accepted.

## Matchmaking

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/matchmaking` | Enter with client-generated `ticketId` and resolved `rules`. |
| `GET` | `/matchmaking?ticketId=…` | Poll that exact ticket for `waiting` or its `matchId`. |
| `DELETE` | `/matchmaking?ticketId=…` | Cancel that exact waiting ticket. |

Queue entries, pointers, and candidate claims use conditional DynamoDB
transactions. A short per-player lock prevents concurrent requests from
matching the same player twice. Tickets are scoped to one request and expire;
status never falls back to an unrelated match from the player's history.
The bounded-TTL candidate row stores the player's opaque ID and public display-
name snapshot alongside rules and ticket metadata so the eventual match can
retain the queued player's name. Pointer and ticket rows do not duplicate the
name, and no queue record contains a username, email address,
provider-generated login identifier, token, or serialized profile. No
secondary matchmaking profile record is created.
If a match wins the race with cancellation, the API returns
`409 matchAlreadyFound` with that ticket's `matchId`; the client opens the
already-committed match.

## Rules request

The default is `{ "mode": "elimination" }`. Alternatives are:

```json
{ "mode": "turnLimitPopulation", "maxPlies": 100 }
```

```json
{ "mode": "populationTarget", "target": 50 }
```

`maxPlies` must be positive and even. `target` is 3–400. The API resolves these
options into the complete, versioned rules document stored with the match.
The only accepted rules document uses `"rulesVersion": 3` and
`"evolution": { "birthOwner": "strictNeighborMajority" }`, so every newborn
cell takes the majority color of its exactly three live neighbors.

All API timestamps are serialized as ISO 8601 UTC values with a `Z` suffix.
DynamoDB TTL attributes are integer Unix seconds derived from the same
UTC-aware instants.

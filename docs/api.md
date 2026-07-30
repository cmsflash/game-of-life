# HTTP API v1

The Flutter application uses one JSON API rooted at `/v1`. Except for health,
registration, login, password recovery, and Google callbacks, endpoints require
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
| `DELETE` | `/me` | Permanently delete the authenticated account; returns `204`. |

The Google flow uses authorization code plus S256 PKCE, signed state, an exact
return-URL allowlist, and two atomic one-time records. Google is optional;
password authentication never contacts it. Local mode uses the same app
callback and exchange shape with an explicitly marked development account.

Account deletion first cancels waiting games and matchmaking requests and
resigns every active game. Completed game records remain available to the
opponent, but the deleted player's identifier and generic color label are replaced
with an unlinkable `Deleted player` identity in both match state and move
history. The deleted player's memberships, matchmaking records, idempotency
records, and identity-provider account are then removed. Existing access and
refresh tokens no longer authenticate.

## Matches

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/matches` | Create a waiting private match. |
| `POST` | `/matches/join` | Join `{joinCode}` and activate the match. |
| `GET` | `/matches` | List the current player's matches. |
| `GET` | `/matches/{id}` | Read one match; supports `If-None-Match`. |
| `DELETE` | `/matches/{id}` | Creator cancels a waiting match. |
| `POST` | `/matches/{id}/moves` | Place a cell and evolve once. |
| `POST` | `/matches/{id}/resign` | Resign an active match. |
| `GET` | `/matches/{id}/moves` | Read its append-only move events. |
| `GET` | `/matches/{id}/replay` | Reproduce and return the canonical replay. |

Match path IDs use canonical 36-character UUID syntax. Other values are
rejected before a repository lookup.
Player summaries deliberately use only the generic labels `Black player` and
`White player`; profile display names are never copied into a match or shown to
an opponent.

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
the separate match `version` advances for every mutation and is the value used
by ETags and DynamoDB conditional writes.

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
Queue rows store only the player's opaque ID, never a display name, serialized
profile, username, or email. No secondary matchmaking profile record is
created.
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
The only accepted rules document uses `"rulesVersion": 2` and
`"evolution": { "birthOwner": "movingPlayer" }`, so every newborn cell belongs
to the player who made the move.

All API timestamps are serialized as ISO 8601 UTC values with a `Z` suffix.
DynamoDB TTL attributes are integer Unix seconds derived from the same
UTC-aware instants.

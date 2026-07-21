# Architecture

## System boundary

The Flutter client has one online dependency: the versioned HTTPS API at
`api.<domain>`. It never connects directly to DynamoDB, the Cognito user-pool
API, or a realtime database. This keeps the mainland-China network path small
and gives the service an interchangeable backend boundary.

```text
Flutter clients
      |
      | HTTPS /v1
      v
API Gateway HTTP API
      |
      v
Python Lambda container ---- Cognito User Pool
      |           |
      |           +---- Google OAuth (optional login path)
      |
      +---- compiled Dart engine executable
      |
      +---- DynamoDB (users, sessions, queues, matches, moves)
```

The Lambda container compiles the same Dart engine package used by Flutter into
a Linux executable during the container build. Python owns HTTP, AWS SDK, and
OAuth concerns; Dart alone owns game transitions.

## Match consistency

Every client command includes:

- a unique idempotency key;
- the match's expected revision;
- the selected row and column.

The API validates the authenticated player's color, calls the Dart engine, and
commits the new snapshot and move event in one DynamoDB transaction. A
conditional expression rejects stale revisions. Retried commands return the
stored response for their idempotency key.

## Authentication

Username/password traffic is proxied through the game API to Cognito. Google
login uses an OAuth authorization-code flow through the same API and produces
the same Cognito token family. Google is never required: a mainland user can
register, verify, sign in, refresh, recover a password, and play using the
username/password endpoints alone.

Access tokens are short-lived. Refresh tokens are accepted only by the API,
rotated where supported, and never logged. The Flutter client stores tokens in
platform secure storage.

## Synchronization

Version 1 uses short HTTPS operations and conditional polling. A match response
has an `ETag` derived from a match-level version that changes for moves,
resignation, and other metadata mutations; `If-None-Match` avoids transferring
an unchanged board. WebSocket notifications can be added later but are never
the authoritative delivery channel.

Quick matchmaking uses a client-generated ticket identifier. Polling and
cancellation always name that exact ticket, and waiting records expire after a
bounded interval so an abandoned device cannot remain an eligible opponent.
Opponent reservation, match creation, both memberships, and ticket completion
commit atomically; a pre-commit failure releases the reservation back to the
queue.

## Portability

The deployment region is a parameter. Hong Kong, Tokyo, and Singapore can run
identical canaries; a field test selects the initial region. Match data starts
in one region. Multi-region replication is deliberately deferred until traffic
and reliability data justify its consistency cost.

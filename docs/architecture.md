# Architecture

## System boundary

After installation or web-app loading, the Flutter client has one runtime
online dependency: the versioned HTTPS API at `api.<domain>`. It never connects
directly to DynamoDB, the Cognito user-pool API, or a realtime database. This
keeps the mainland-China gameplay path small and gives the service an
interchangeable backend boundary.

```text
Browser ---- CloudFront ---- private S3 Flutter build
   |             |
   |             +---- route-rewrite function + security headers
   |
Native and web Flutter clients
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
                 |
                 +---- state stream ---- notification Lambda
                                           |          |
                                           |          +---- Web Push / Firebase
                                           v
                                    EventBridge Scheduler
                                     (8h / 24h / 72h)
```

The Lambda container compiles the same Dart engine package used by Flutter into
a Linux executable during the container build. Python owns HTTP, AWS SDK, and
OAuth concerns; Dart alone owns game transitions.

CloudFront signs every S3 origin request with origin access control. The origin
bucket is not public. The web release packages CanvasKit locally and CloudFront
rewrites extensionless application URLs, including `/auth/callback`, to the
Flutter shell while leaving static-asset paths unchanged. Flutter fallback-font
requests use a same-origin `/font-fallback/` path; CloudFront fetches and caches
the corresponding versioned font files server-side, so browsers do not connect
to Google's font hostname.

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

Push notifications are likewise advisory rather than authoritative. Activating
a match or committing a move updates the match snapshot first. DynamoDB Streams
then invokes a separate notification worker, which sends the immediate alert
and creates three one-time EventBridge schedules. Each delivery performs a
strongly consistent match read and requires the same active status, engine
revision, player-to-move, and recipient ID captured at turn start. A move,
resignation, or completed game therefore invalidates all earlier reminders
without requiring schedule cancellation.

Provider messages use zero-second retention and one collapse identifier per
match. Push services therefore cannot retain alerts for an offline device or
later release an accumulated burst after that turn has become stale.

Delivery claims are stored per match revision, reminder offset, and
installation. Retries normally send once; an unavoidable crash between a push
provider accepting a message and recording completion can still produce a
duplicate, so provider collapse identifiers are deterministic. Expired device
tokens are removed. Failed stream records and exhausted scheduled jobs enter an
encrypted dead-letter queue, whose visible-message alarm covers partial stream
failures that do not increment the Lambda error metric.

Browser endpoints are accepted only for an operator-configured push-service
hostname allowlist, preventing the delivery worker from becoming an SSRF path.
Push provider credentials remain in Secrets Manager. The API stores the
encrypted subscription record but returns only token-free installation
metadata. The stream consumer filters before invocation to match records only,
and its table permissions allow reads only for match/subscription state and
writes only for delivery claims or subscription cleanup.

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

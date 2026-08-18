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
revision, active account state, and player-to-move. Scheduled inputs are identity-
free: they contain the match ID, revision, reminder offset, and turn-start time,
then derive the recipient from the authoritative match at execution. A move,
resignation, or completed game therefore invalidates all earlier reminders
without requiring schedule cancellation.

Provider messages use zero-second retention and one collapse identifier per
match. Push services therefore cannot retain alerts for an offline device or
later release an accumulated burst after that turn has become stale.

Delivery claims are stored per match revision, reminder offset, and
installation. Retries normally send once; an unavoidable crash between a push
provider accepting a message and recording completion can still produce a
duplicate, so provider collapse identifiers are deterministic. The worker
re-reads each subscription immediately before sending. Expired credentials are
deleted only when the stored subscription still exactly matches the attempted
value; a concurrent refresh releases the delivery claim and retries against the
new value instead. Failed stream records and exhausted scheduled jobs enter an
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

Private-room creation retains the creator's authenticated public display name,
and joining snapshots the second player's display name into the activated
match. A quick-match candidate carries the same public snapshot in its bounded-
TTL queue row so the atomic match commit can associate both names with their
randomly assigned colors without a second profile service. Login usernames,
email addresses, and tokens never enter match documents or queue rows. Account
deletion replaces only the departing participant's stored name and identifier
with an unlinkable `Deleted player` identity.

## Social graph, discovery, and ratings

Every active public profile is indexed by normalized display-name prefixes of
length one, two, and three (where available), so even one-character names are
findable without scanning. Search rate-limits each subject, caps responses, batch-
hydrates canonical profiles behind account-state fences, and returns only opaque
ID, display name, rating, and versioned picture reference. Login username and email
never enter the index. Account deletion removes every prefix row.

Uploaded pictures are authenticated, rate-limited, decoded under strict size/type
bounds, and re-encoded as fixed 512×512 WebP before entering a retained private S3
bucket. A profile transaction publishes only a random server-owned key and updates
a SHA-256-keyed current-avatar pointer. A new object remains `pending` through its
pointer transaction and gets a durable identity-free delayed SQS check. A replaced,
removed, or deleting account's old key is queued and tagged `orphan` before the
pointer fence. The worker promotes an exact current pointer to `active` and deletes
anything else; request-side deletion is only an optimization. Pending/orphan
lifecycle expiry, queue retries, an alarmed DLQ, and operator remediation cover
cross-store and Lambda crash windows without allowing an unreferenced request to
create an active object. Match responses batch-hydrate current picture versions
rather than persisting picture URLs in matches.

Friendship uses one canonical unordered-pair record plus one projection per user.
Conditional transactions update both projections, both bounded counters, and both
Social snapshot versions. Pending direct challenges are separate seven-day records,
not waiting matches. Acceptance rechecks friendship/expiry/account state and
atomically creates one active randomly colored match, both memberships, and a
recoverable challenge-result pointer. DynamoDB TTL is a retention backstop; Social
reads repair partial expiry and counters.

Every remote terminal transition writes the completed match, terminal move or
resignation idempotency result, both player-stat updates, a participant-free
per-match metrics ledger, and a global metrics-control sequence in one transaction.
The global sequence serializes Elo updates across concurrently finishing matches.
Rating begins at 1200, uses K=32 and symmetric half-away-from-zero rounding, and is
an unbounded signed integer with exactly inverse deltas. Kill counters accumulate
from authoritative death colors on every move: Black deaths credit White and White
deaths credit Black. Durable player-stat rows retain finalized-match kills. A
personal stats read first loads that finalized row, then strongly reads the player's
active rated match snapshots and adds the cumulative counter for the player's color.
This ordering cannot double-count the atomic active-to-terminal handoff; a terminal
commit between the two reads can only produce a transient undercount until the next
refresh. Legacy active snapshots without a complete cached counter reconstruct it
from a strongly consistent, contiguous move history, capped at the snapshot revision
to tolerate a concurrent later move.

The `CONTROL#METRICS` record fails closed when missing. During the initial
chronological backfill it is `backfilling`: nonterminal play continues, but terminal
commits, Social/rating reads, and account deletion return a retryable 503. The
dry-run-first migration orders attributable completed matches by authoritative
terminal time and match ID, conditionally writes one contiguous ledger sequence,
verifies exact aggregate stats, and only then sets `ready`. Completed histories
whose players were already anonymized cannot be attributed and are conditionally
marked `rated=false` without changing gameplay timestamps.

Account deletion first writes a durable state fence under a SHA-256-derived key and
a one-day raw-sub rolling-deployment guard. Every identity-bearing creation or move
transaction checks the fence. Cleanup removes Social/search/stats rows and uses CAS
loops to anonymize retained matches, moves, and counterpart command snapshots, so
concurrent deletion of both participants cannot restore either identity.

## Portability

The deployment region is a parameter. Hong Kong, Tokyo, and Singapore can run
identical canaries; a field test selects the initial region. Match data starts
in one region. Multi-region replication is deliberately deferred until traffic
and reliability data justify its consistency cost.

# Production operations

## Service inventory

The CloudFormation stack is the ownership boundary. Its outputs identify the
API, Lambda function, DynamoDB table, Cognito pool/client, Hosted UI, and SNS
alarm topic. It also owns a retained private profile-picture bucket, cleanup
queue/dead-letter queue, and cleanup worker. Use stack outputs instead of copying
resource names into scripts.
When push is enabled, outputs also identify the notification worker and its
dead-letter queue.

The API Gateway routes are deliberately broad (`ANY /` and
`ANY /{proxy+}`), while FastAPI owns route-level authentication and validation.
Public registration and OAuth endpoints and authenticated game endpoints share
one Lambda integration. The Lambda IAM role can read and transact only against
the stack's game table; Cognito end-user calls are authorized by the public app
client or bearer token rather than broad administrative IAM permissions.

## Post-deployment checks

Run these checks after every stack update from at least two networks:

1. `GET /v1/health` returns success through both `ApiBaseUrl` and
   `ApiExecuteUrl`.
2. Register a disposable username, receive the email code, confirm, sign in,
   refresh, sign out, request a reset code, and reset the password.
3. If enabled, complete Google login and verify the one-time exchange code
   cannot be used twice.
4. Create and join a match with two accounts, submit one legal move, retry it
   with the same idempotency key, and verify only one move exists.
5. Poll with the returned `ETag` and verify an unchanged match returns `304`.
6. Delete one disposable account while it is waiting and another while it is
   in an active match. Verify the queue entry is removed, the active match is
   resigned, retained match history no longer contains the account identifier,
   the old token is rejected, and a new account can reuse the username.
7. Repeat the health, password-login, and move checks using the mainland
   carriers and times listed in [`mainland-validation.md`](mainland-validation.md).
8. If push is enabled, register one clean browser or device installation, join
   a match, and verify the player-to-move receives one immediate alert. Submit a
   move before a test reminder fires and verify the old revision sends nothing.
   Use an isolated short-delay operator test only for deployment validation;
   production offsets remain 8, 24, and 72 hours.
9. With two disposable accounts, verify one-, two-, and three-character normalized
   public-display-name prefix search, send
   and accept a friend request, create and accept a direct challenge, and confirm
   a lost-response retry returns the same match ID. Complete it and verify both
   stats records changed once and their rating deltas sum to zero.
10. Upload, replace, remove, and re-upload a disposable account's picture. Verify
    the output is a 512×512 WebP, the current version is publicly readable with a
    60-second revalidating cache bound, each superseded URL returns `404`, and a
    match GET with its prior ETag returns `200` with the new picture version.

Do not treat a successful test from an overseas VPN or one mainland ISP as a
reachability guarantee.

## Logs and alarms

The stack retains the API and access-log groups for the configured retention
period, plus a notification-worker group when push is enabled:

- `/aws/lambda/FUNCTION_NAME` for application/runtime logs;
- `/aws/apigateway/STACK_NAME` for structured request access logs.
- `/aws/lambda/life-ENVIRONMENT-notifications` for delivery and scheduling failures.
- `/aws/lambda/life-ENVIRONMENT-avatar-cleanup` for delayed private-object cleanup.

The access log includes request ID, source IP, route, status, response size,
and integration error, but not authorization headers or request bodies. The
application must likewise never log access tokens, refresh tokens, passwords,
confirmation codes, OAuth codes, or full game-auth responses.

Four API alarms publish to `AlarmTopicArn`; every stack also alarms on
profile-picture cleanup errors and dead-letter depth, while push-enabled stacks
add alarms for notification-worker errors and visible dead-lettered jobs:

- five Lambda errors in five minutes;
- any Lambda throttling in five minutes;
- five API 5xx responses in five minutes;
- API p99 latency above five seconds for three consecutive five-minute periods.
- any notification-worker error in five minutes.
- any notification or reminder that exhausts retries and reaches the
  notification dead-letter queue.
- any profile-picture cleanup worker error in five minutes;
- any profile-picture cleanup message that exhausts retries and reaches its
  dead-letter queue.

If `AlarmNotificationEmail` was supplied, confirm the SNS subscription email;
unconfirmed subscriptions receive nothing. Production teams should also
subscribe an incident system to the topic.

Useful log tails:

```bash
aws logs tail /aws/lambda/FUNCTION_NAME \
  --region AWS-REGION \
  --since 30m \
  --follow
```

```bash
aws logs tail /aws/apigateway/STACK-NAME \
  --region AWS-REGION \
  --since 30m \
  --follow
```

## Incident runbooks

### Elevated 5xx or Lambda errors

1. Check API access logs for affected request IDs and routes.
2. Correlate those IDs with Lambda logs; distinguish cold-start/configuration
   failure from an application exception.
3. Check Lambda `Errors`, `Duration`, `ConcurrentExecutions`, and DynamoDB
   `SystemErrors` and throttling metrics.
4. If the incident began with a release, redeploy the last known-good source
   revision. CloudFormation remains the source of truth.
5. Verify one password login and one complete two-player move after recovery.

### Throttling or high latency

1. Check whether API stage throttling (50 requests/second, burst 100), the
   regional Lambda account quota, or another function using the shared pool is
   the limiting layer.
2. Inspect DynamoDB consumed capacity and throttling before raising concurrency.
3. Reject abusive clients at the edge or application layer; do not remove all
   limits during an incident.
4. Increase parameters through a reviewed stack update, then confirm latency
   and error alarms return to OK.

### Authentication outage

1. Test username/password independently from Google.
2. If password login works, inspect the Cognito Hosted UI, Google provider
   configuration, secret rotation history, and both OAuth callback URLs.
3. If all Cognito operations fail, check the regional Cognito service health
   and application environment values from stack outputs/template—not logs.
4. Keep username/password visible as the mainland-safe login path even during a
   Google-only outage.

### Match write conflicts

Expected conditional-write failures indicate stale revisions or duplicate
requests, not data loss. Confirm the client supplied an expected revision and
idempotency key. Investigate only if a committed move lacks its matching event,
because snapshots, move events, and idempotency records should be written in
one DynamoDB transaction.

### Turn-notification failures

1. Check the notification Lambda error alarm and
   `/aws/lambda/life-ENVIRONMENT-notifications` logs. Logs must identify the
   provider and request class without printing endpoints, tokens, encryption
   keys, or service-account content.
2. Check the EventBridge Scheduler group for future one-time schedules and the
   `NotificationDeadLetterQueueUrl` output for exhausted stream or scheduled
   jobs. Redrive only after correcting credentials or provider availability;
   revision checks make late jobs safe.
   The queue-depth alarm is also the signal for partial DynamoDB stream failures,
   because those are reported to Lambda as successful invocations with failed
   item identifiers.
   Current schedules contain no player identity; the worker resolves the current
   recipient from the authoritative match at invocation. Do not add a synchronous
   account-deletion scan of the shared schedule group. Legacy recipient-bearing
   schedules from the notification rollout fail closed for deleted accounts and
   self-delete after their scheduled run, within 72 hours.
3. Confirm each provider secret exists in the same region and matches the exact
   ARN deployed in the function environment. Do not print `SecretString`
   during diagnosis.
4. For Web Push, verify the public/private VAPID pair and subject, then test a
   newly registered browser endpoint. For Firebase, verify the service account
   can send FCM HTTP v1 messages and that APNs is configured for iOS.
5. A Web Push `404`/`410`, or a structured Firebase `UNREGISTERED` error,
   removes that installation automatically. A generic Firebase `404` is treated
   as a configuration/provider failure so it cannot erase valid tokens.
   Repeated transient errors retain the subscription and retry through the
   stream or schedule policy.

### Profile-picture cleanup failures

1. Check `AvatarCleanupFunctionErrorAlarm`,
   `AvatarCleanupDeadLetterQueueAlarm`, and
   `/aws/lambda/life-ENVIRONMENT-avatar-cleanup`. Log and queue payloads contain
   only an owner SHA-256 digest and hashed-prefix object key; do not join either
   value back to identity-provider data during routine diagnosis.
2. Read `AvatarCleanupQueueUrl` and `AvatarBucketName` from stack outputs. Confirm
   the queue event source is enabled, its visible/in-flight counts are falling,
   the worker can read only `ACCOUNT#…` state/pointer rows, and it can delete only
   `avatars/…` objects in the private bucket.
3. Fix IAM, S3, DynamoDB, or worker errors before redriving the cleanup DLQ.
   The worker rereads the authoritative account fence and picture pointer, so a
   late redrive keeps the exact current object and deletes only unreferenced ones.
   Never bulk-delete a prefix based only on a queue message.
4. Confirm S3 public-access blocking remains fully enabled and both `pending` and
   `orphan` lifecycle rules remain enabled with approximately one-day expiry.
   A cleanup message and its DLQ copy can be retained for up to 14 days, but no
   raw player ID is present.
5. For a disposable account, replace a picture and verify the old delivery URL
   immediately returns `404`. If immediate S3 deletion is faulted, confirm a
   cleanup message exists and the private object normally disappears after redrive
   or lifecycle processing; investigate the alarm and remove a verified noncurrent
   key if a cross-store race persists. An account-deletion race may leave a private pre-fence upload
   until the roughly 15-minute delayed check; the fenced public route must remain
   `404` throughout.

## Data protection and recovery

The table uses on-demand capacity, AWS KMS encryption, TTL on `expiresAt`,
point-in-time recovery, deletion protection, and retain-on-delete/update. TTL is
asynchronous and must not be used as an authorization check; the application
must reject an expired exchange or queue entry even before DynamoDB removes it.

Account deletion removes the identity and matchmaking state, resigns active
matches, and replaces the account identifier in retained match history with an
anonymous participant identifier. It also removes all push subscriptions and
installation ownership records, directory/search rows, Social edges, challenges,
and player stats. A durable SHA-256-keyed state tombstone prevents identity-provider
deletion failures from recreating the account without retaining the raw subject;
the rolling raw-sub guard expires after one day. Operational backups may retain the prior
value until their documented recovery window expires; see
[`privacy-policy.md`](privacy-policy.md).

Account deletion also atomically fences the public profile and current picture
pointer, then makes a best-effort synchronous pass over that account's hashed S3
prefix before deleting the identity. A pre-fence upload can finish its private
PUT after that pass. It cannot be delivered because the account/profile CAS has
failed; the already-enqueued authoritative check removes it after about 15
minutes, with the `pending`/`orphan` lifecycle as an approximately one-day
fallback. Do not claim that byte removal is synchronous in operator or store
responses.

Before a schema or repository change:

1. Confirm point-in-time recovery reports `ENABLED`.
2. Export or back up data if the migration changes stored shapes.
3. Deploy code capable of reading both old and new records before backfilling.
4. Use small, resumable batches and measure throttling.

### Public discovery and profile-picture cutover

Use this order for the first public-by-default/profile-picture release. Do not
publish the matching web or Flutter build early:

1. Deploy the compatible API stack first. Its private retained S3 bucket,
   cleanup queue/DLQ, cleanup Lambda, lifecycle rules, alarms, public-version
   delivery route, account fence, and new writers must all exist before data is
   migrated. Keep the prior client live during this step.
2. Wait longer than the old API Lambda's maximum invocation time (currently 29
   seconds) so no old writer can still commit a hidden or first-three-only row.
3. Read `DynamoTableName` from the stack, confirm point-in-time recovery is
   enabled, and run the migration without `--apply`:

   ```bash
   python -m life_api.migrate_public_players \
     --table-name DYNAMO_TABLE_NAME \
     --region ap-east-1 \
     --profile game-of-life
   ```

   Require `invalid=0` and `conflicts=0`. The plan validates exact profile
   PK/SK, top-level/document version and public flag, normalized display name,
   every one- through three-character prefix row, and reports stale or orphaned
   search rows. Any invalid row blocks all writes and must be investigated.
4. Repeat with `--apply`:

   ```bash
   python -m life_api.migrate_public_players \
     --table-name DYNAMO_TABLE_NAME \
     --region ap-east-1 \
     --profile game-of-life \
     --apply
   ```

   Each profile update is conditioned on the exact prior
   document/version and both account-deletion fences. Stale index deletion is
   conditioned on its exact player/document; orphan deletion is conditioned on
   the profile still being absent. Concurrent rename, picture, or deletion work
   therefore wins safely and appears as a conflict to rerun.
5. Rerun the read-only command from step 3 and require `eligible=0`, `stale_indexes=0`,
   `orphan_indexes=0`, `invalid=0`, and `conflicts=0`.
6. With active disposable accounts whose normalized names are one, two, and at
   least three characters long, verify `/v1/players/search` succeeds using each
   available prefix and returns the current display name/rating/picture only—no
   username or email. Verify a deleting/deleted account is absent.
7. Smoke-test picture upload/replacement/removal, the cleanup queue and DLQ
   attributes, both cleanup alarms, S3 public-access block, lifecycle rules, and
   the account-prefix race behavior in the cleanup runbook above.
8. Update the web stack's `ApiOrigin` and only then publish the web/Flutter
   build. After CloudFront finishes, inspect the live response header and require
   the exact API origin (scheme and host only) in `img-src`:

   ```bash
   curl -fsSI WEB_BASE_URL/ | tr -d '\r' | \
     grep -F "content-security-policy:" | grep -F "img-src 'self' data: blob: API_ORIGIN;"
   ```

The compatibility endpoint `PATCH /v1/social/discoverability` remains available
for rolling clients but always returns `discoverable:true`; new clients expose no
privacy toggle. The API continues to read legacy false/missing picture fields.
Rollback only to this compatible API release or newer after migration—an older
writer could recreate hidden or incomplete prefix rows. A web/Flutter rollback
is safe because all new public-player and match picture fields are additive and
nullable, but the deployed CSP must retain the API origin.

### Legacy match display-name migration

The backend writes public display-name snapshots into all new private and quick
matches. Records created before that behavior can be backfilled with the
dry-run-first migration command below. It resolves each stored Cognito subject
to the same trimmed `name` (or Cognito username fallback) used by
authentication, skips already named and deleted participants, and never prints
resolved names or account IDs.

From an activated backend environment installed with the `[dev]` extra (which
includes the AWS login-profile credential provider), inspect one match first:

```bash
python -m life_api.migrate_match_display_names \
  --stack-name the-game-of-life-production \
  --region ap-east-1 \
  --profile game-of-life \
  --match-id MATCH_UUID
```

Omit `--match-id` for a read-only full-table dry run. After confirming point-in-
time recovery, counts, and the target stack, repeat the same command with
`--apply`; then rerun the dry run and require `eligible=0`, `unresolved=0`,
`conflicts=0`, and `invalid=0`. A conditional write compares both the complete
stored document and its prior match version, so a concurrent move wins safely
and appears as `conflicts`; rerun those records after gameplay settles.

Each applied repair increments the match version so ETag-based clients refetch,
but deliberately preserves `updatedAt`, engine revision, and player-to-move.
History ordering and reminder timing therefore remain unchanged, and the
notification stream does not classify the repair as a new turn.

### Initial Social, stats, and Elo cutover

The rating migration is deliberately fenced and dry-run first. Use an activated
backend virtual environment installed with the `[dev]` extra so the AWS login
profile provider (`botocore[crt]`) is available. Confirm point-in-time recovery,
deploy the compatible backend, then wait longer than the old API Lambda's maximum
29-second invocation time before starting the fence. Until `CONTROL#METRICS` is
`ready`, new code fails closed for terminal results, Social/rating reads, and all
account deletion; nonterminal moves can continue.

Run each phase without `--apply` first, inspect the JSON report, then repeat with
`--apply` only when `invalid=0` and `conflicts=0`:

```bash
python -m life_api.migrate_ratings plan \
  --stack-name the-game-of-life-production --region ap-east-1 \
  --profile game-of-life
python -m life_api.migrate_ratings begin \
  --stack-name the-game-of-life-production --region ap-east-1 \
  --profile game-of-life --apply
python -m life_api.migrate_ratings apply \
  --stack-name the-game-of-life-production --region ap-east-1 \
  --profile game-of-life
python -m life_api.migrate_ratings apply \
  --stack-name the-game-of-life-production --region ap-east-1 \
  --profile game-of-life --apply
python -m life_api.migrate_ratings finish \
  --stack-name the-game-of-life-production --region ap-east-1 \
  --profile game-of-life
python -m life_api.migrate_ratings finish \
  --stack-name the-game-of-life-production --region ap-east-1 \
  --profile game-of-life --apply
```

`plan` also reports missing confirmed-user public profiles; `apply` creates them
as public and writes each available one-, two-, and three-character search
prefix. Completed matches are globally ordered by authoritative
terminal time and match ID. Each attributable match conditionally writes one
contiguous `ratingSequence`, both exact stats transitions, reconstructed kills,
and a participant-free ledger. Legacy histories whose participants were already
anonymized cannot be attributed: the migration reports `excluded_legacy`, marks
them `rated=false`, increments their match version for ETag invalidation, and
preserves state, result, `createdAt`, and `updatedAt`.

Before `finish --apply`, require `eligible=0`, `would_apply=0`, no orphan or
malformed ledgers, exact stats/ledger replay, contiguous `globalVersion`, and a
public profile for every confirmed active Cognito user. The command exits
nonzero if finish is incomplete. After ready, verify `/v1/stats/me`, `/v1/social`,
and a rated terminal result before deploying the matching web release. Never apply
historical Elo after live rated completions; the control fence is what guarantees
chronological determinism.

A DynamoDB point-in-time restore always creates a new table. Restore to a new
name, validate record counts and representative matches, then deploy a reviewed
configuration change that points the application at the recovered table. Do
not delete the original table during incident response.

Cognito and DynamoDB are retained if the stack is deleted. Recreating a stack
does not automatically adopt retained resources. Record their IDs/ARNs before
any teardown and use a deliberate import or migration plan.

## Security operations

- The Cognito app client is public (`GenerateSecret: false`) by design; a
  client secret cannot be protected in a Flutter binary. OAuth authorization
  code, exact redirect allowlists, signed state, and one-time exchange codes
  provide the relevant controls.
- The Google provider secret lives in Secrets Manager and is resolved into the
  Cognito provider by CloudFormation. Rotate it on a schedule and immediately
  retest both login paths.
- Review CORS and return URL parameters on every new frontend hostname. Remove
  obsolete origins rather than accumulating them.
- Keep API Gateway execution, Lambda, DynamoDB, and Cognito in one selected
  region until an explicit multi-region data-consistency design is implemented.
- Enable CloudTrail management-event retention at the account/organization
  level; it is intentionally outside this application stack.
- Apply account-level cost budgets and anomaly detection. On-demand DynamoDB
  does not impose a fixed monthly ceiling.

## Capacity changes

The initial limits are conservative: API stage rate 50/second with burst 100,
Lambda using the regional shared concurrency pool, and DynamoDB on-demand.
Load-test complete match turns—not only health checks—before increasing them. A
move invokes the compiled engine and performs a transactional write, so request
cost and duration differ substantially from read polling.

`LambdaReservedConcurrency=0` omits the reservation. Before setting it to a
positive number, raise or verify the regional account quota so the reservation
still leaves at least 10 unreserved executions for the account.

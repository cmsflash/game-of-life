# Production operations

## Service inventory

The CloudFormation stack is the ownership boundary. Its outputs identify the
API, Lambda function, DynamoDB table, Cognito pool/client, Hosted UI, and SNS
alarm topic. Use stack outputs instead of copying resource names into scripts.

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
6. Repeat the health, password-login, and move checks using the mainland
   carriers and times listed in [`mainland-validation.md`](mainland-validation.md).

Do not treat a successful test from an overseas VPN or one mainland ISP as a
reachability guarantee.

## Logs and alarms

The stack retains two CloudWatch log groups for the configured retention
period:

- `/aws/lambda/FUNCTION_NAME` for application/runtime logs;
- `/aws/apigateway/STACK_NAME` for structured request access logs.

The access log includes request ID, source IP, route, status, response size,
and integration error, but not authorization headers or request bodies. The
application must likewise never log access tokens, refresh tokens, passwords,
confirmation codes, OAuth codes, or full game-auth responses.

Four alarms publish to `AlarmTopicArn`:

- five Lambda errors in five minutes;
- any Lambda throttling in five minutes;
- five API 5xx responses in five minutes;
- API p99 latency above five seconds for three consecutive five-minute periods.

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

1. Check whether API stage throttling (50 requests/second, burst 100) or Lambda
   reserved concurrency (20 by default) is the limiting layer.
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

## Data protection and recovery

The table uses on-demand capacity, AWS KMS encryption, TTL on `expiresAt`,
point-in-time recovery, deletion protection, and retain-on-delete/update. TTL is
asynchronous and must not be used as an authorization check; the application
must reject an expired exchange or queue entry even before DynamoDB removes it.

Before a schema or repository change:

1. Confirm point-in-time recovery reports `ENABLED`.
2. Export or back up data if the migration changes stored shapes.
3. Deploy code capable of reading both old and new records before backfilling.
4. Use small, resumable batches and measure throttling.

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
Lambda reserved concurrency 20, and DynamoDB on-demand. Load-test complete
match turns—not only health checks—before increasing them. A move invokes the
compiled engine and performs a transactional write, so request cost and
duration differ substantially from read polling.

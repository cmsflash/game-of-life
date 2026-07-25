# Mainland connectivity release gate

The AWS provider name or a successful request to a generic AWS hostname is not
enough to approve a production launch. Validate the exact application domains
and operations from physical mainland devices.

## Candidate deployments

Deploy the same immutable backend image and infrastructure revision to:

- Asia Pacific (Hong Kong), `ap-east-1`;
- Asia Pacific (Tokyo), `ap-northeast-1`;
- Asia Pacific (Singapore), `ap-southeast-1`.

Use the intended custom domain for each candidate. Do not substitute the AWS
console, an S3 root, or a provider marketing page.

Deploy the production CloudFront web stack and test its exact `WebBaseUrl` as
well. The web distribution is global and can point the same immutable Flutter
build at each candidate API in separate tests.

## Probe matrix

Test China Mobile, China Telecom, and China Unicom on both fixed broadband and
cellular service. Include several provinces and at least one Chinese-market
Android device without Google Play Services. Run non-mainland controls at the
same time.

Every five minutes for at least fourteen days, execute:

```text
resolve web and API DNS
→ establish TCP and TLS
→ load / and a direct application route such as /auth/callback
→ fetch the locally hosted CanvasKit and application bundles
→ render Latin and Chinese test names through the same-origin font proxy
→ register/login with username and password
→ refresh the token
→ create or join a match
→ submit a move
→ poll until the opponent sees the revision
→ disconnect and reconnect
→ retrieve and verify the replay
```

Google login is measured separately and is not a mainland release dependency.

## Recorded fields

- UTC timestamp, city, carrier/ASN, access type, OS, app version, and region;
- DNS, TCP, TLS, first-byte, and total request durations;
- web-shell, JavaScript, CanvasKit, font, and service-worker fetch results;
- HTTP status and stable application error code;
- login, refresh, command, polling, and reconnect success;
- p50, p95, and p99 latency by operation, carrier, city, hour, and region;
- state/revision agreement between both players;
- timeout, reset, DNS, TLS, throttling, and server-failure counts.

The release decision is based on the complete authenticated move flow, not on a
binary “blocked” label. Preserve the raw measurements so a later routing change
can be compared with the original baseline.

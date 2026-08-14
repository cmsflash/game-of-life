# Life API

The API is server-authoritative and exposes every online operation through one
versioned HTTPS boundary. Local mode uses in-memory identity and data adapters;
production mode uses Cognito and DynamoDB.

## Run locally

From the repository root:

```bash
make bootstrap
make run-backend
```

Local registration responses include a development-only confirmation code.
Local Google login creates a development account through the same one-time-code
callback shape as production. Neither behavior is enabled when `APP_ENV` is
`production`.

Interactive API documentation is available at `http://localhost:8080/docs`.
The stable route and payload contract is documented in
[`docs/api.md`](../docs/api.md).

Push delivery is disabled by default. Production can enable standard Web
Push/VAPID, Firebase mobile push, or both without changing the subscription API.
Match table stream events drive immediate turn alerts; one-time EventBridge
Scheduler jobs provide the 8-, 24-, and 72-hour reminders. Provider credential
and CloudFormation requirements are documented in
[`docs/deployment.md`](../docs/deployment.md#turn-push-notifications).

## Authoritative engine

During local development the API runs the Dart CLI using the installed SDK. The
production image compiles `tools/game_cli` to a Linux executable and copies only
that executable into the Lambda image. The Python service never reimplements a
game transition.

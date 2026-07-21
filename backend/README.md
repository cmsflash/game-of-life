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

## Authoritative engine

During local development the API runs the Dart CLI using the installed SDK. The
production image compiles `tools/game_cli` to a Linux executable and copies only
that executable into the Lambda image. The Python service never reimplements a
game transition.

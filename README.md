# The Game of Life

The Game of Life is a deterministic, two-player strategy game derived from
Conway's Game of Life. Players alternate placing a colored cell and the board
then evolves once. In current rules, every newborn cell belongs to the player
whose move triggered that evolution.

This repository contains the complete cross-platform product:

- `apps/game_app` — Flutter application for Android, iOS, web, macOS, Windows,
  and Linux.
- `packages/game_engine` — pure, deterministic Dart rules engine shared by
  local play, the client, tests, and the authoritative server executable.
- `tools/game_cli` — JSON/JSONL command-line interface for automation and AI.
- `backend` — server-authoritative HTTP API, authentication bridge,
  matchmaking, persistence, and replay service.
- `infra` — AWS deployment templates for one global HTTPS API boundary and a
  private-S3/CloudFront Flutter web application.
- `docs` — rules, API, architecture, operations, and deployment documentation.

## Development

Prerequisites are Flutter 3.44.7 or newer, Dart 3.12 or newer, Python 3.12 or
newer, and Docker. Then run:

```bash
make bootstrap
make test
```

Then start the two development processes in separate terminals:

```bash
# Terminal 1
make run-backend

# Terminal 2
make run-app
```

The local app uses `http://localhost:8080`. A deployed API can be selected
without rebuilding source code:

```bash
flutter run \
  --dart-define=API_BASE_URL=https://api.example.com
```

Release builds intentionally reject a missing, local, or plaintext API origin.
Use the exact production HTTPS origin for every candidate artifact. Optional
Google sign-in is hidden from release builds unless it is explicitly enabled;
it remains hidden on Apple platforms until an equivalent compliant login
provider is implemented.

## Publication

The client includes in-app privacy, Terms, open-source license, and account
deletion surfaces. The API deletes the identity account, resolves outstanding
matches, and anonymizes retained history. Opponent-authored names are not
exposed in the release protocol.

Before submitting a binary, complete the operator-specific values, store
assets, reviewer package, signing, and clean-device checks in
[`docs/store-publication.md`](docs/store-publication.md). The canonical policy
texts are [`docs/privacy-policy.md`](docs/privacy-policy.md) and
[`docs/terms-of-use.md`](docs/terms-of-use.md).

Cloud credentials, OAuth client secrets, signing secrets, and DNS ownership are
deployment inputs and are never committed to this repository. See
`docs/deployment.md` for the complete setup.

## Architecture principles

- The server is authoritative for every online transition.
- The engine is pure and deterministic; it contains no Flutter, persistence,
  networking, randomness, or wall-clock dependencies.
- Every match stores a resolved, versioned rules document and append-only move
  history.
- Online writes use an expected revision and an idempotency key.
- Mainland clients need only the game's custom HTTPS API domain. Google login
  is optional; username/password registration remains fully supported.

This project is currently private and is not licensed for redistribution.

# Production acceptance criteria

## Offline product

- The application launches without an account on all Flutter target platforms.
- A local two-player match starts from the centered diagonal 2 by 2 position.
- Every legal tap places the correct color and performs exactly one simultaneous
  evolution.
- Every newborn cell produced by a turn belongs to the player who made that
  move; stored version 1 replays retain their historical majority-color rule.
- The last-move indicator outlines its coordinate without covering a surviving
  Black or White cell.
- Isolated placements visibly consume a turn even if the final board is
  unchanged.
- Elimination, turn-limit population, and population-target modes finish with
  deterministic outcomes.
- Recorded move sequences can be replayed deterministically through the shared
  engine and command-line interface.

## Accounts

- A user can register with username, email, and password; confirm their email;
  sign in; refresh; sign out; recover a forgotten password; and reset it.
- A user outside mainland China can alternatively use Google login.
- Google is optional throughout the UI and backend.
- Tokens are stored using the platform secure-storage implementation and are
  removed on logout.
- A signed-in user can permanently delete the account in the app. Waiting
  matches are cancelled, active matches are resigned, identity data is
  deleted, and retained history is anonymized.
- Privacy Policy, Terms of Use, open-source licenses, and account-deletion
  guidance are reachable in the app without an online match.

## Online play

- A user can create a match and share a short join code.
- A second user can join by code or both can use quick match.
- Players receive opposite colors and Black moves first.
- The service rejects moves by spectators, moves on the wrong turn, occupied
  coordinates, stale revisions, and duplicate commands.
- A successful command atomically persists the snapshot and append-only move.
- Polling returns `304 Not Modified` when the match version is unchanged.
- Both players can load the same replay and independently reproduce its final
  state hash.
- Resignation produces a terminal outcome and prevents future moves.
- Opponents receive color labels rather than user-authored usernames or display
  names.

## Operational quality

- Engine, CLI, backend, and Flutter tests pass in CI.
- The backend container builds without relying on the developer's installed Dart
  SDK.
- The infrastructure template can create the API, table, Cognito resources,
  permissions, logs, alarms, and documented outputs in a parameterized AWS
  Global region.
- Production secrets are deployment inputs, not source-controlled values.
- Release clients reject missing, plaintext, or local API origins and Android
  release tasks reject debug signing.
- The board is operable by touch, keyboard, and assistive technologies, and
  narrow screens do not require horizontal scrolling for match status.
- Route and victory-mode changes never paint outgoing and incoming content at
  the same time.
- The exact deployed authentication and move flow is measured from mainland
  China before public launch.

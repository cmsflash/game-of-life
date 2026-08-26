# Production acceptance criteria

## Offline product

- The application launches without an account on all Flutter target platforms.
- A local two-player match starts from the centered diagonal 2 by 2 position.
- Every legal tap previews the board after the correct-color placement and one
  simultaneous evolution without consuming the turn.
- Tapping another empty cell replaces the preview; only the separate player-
  colored check control commits the selected move and advances one turn.
- Every newborn cell takes the majority color of its exactly three live
  neighbors. Only rules version 3 with `strictNeighborMajority` birth ownership
  is accepted.
- Cells that exist only in the preview are translucent while surviving current
  cells remain opaque.
- Game-view settings offer a `Visualize deaths in preview` option. When enabled,
  cells that will die remain as faded, original-color stones with a coral cross;
  when disabled, those cells disappear from the preview.
- A light-green corner shutter surrounds the tentative coordinate and remains
  on the committed last-move coordinate, even if that placed cell dies.
- Isolated placements visibly consume a turn even if the final board is
  unchanged.
- Elimination, turn-limit population, and population-target modes finish with
  deterministic outcomes.
- Local setup supports human vs human, player vs AI with either human color,
  and AI vs AI. AI level 1 maximizes cell advantage after one move; AI level 2
  maximizes the worst-case cell advantage after every legal opponent reply.
- Player vs AI has one level selector. AI vs AI supports independent levels
  for Black and White.
- A single AI opponent responds exactly once after a human move. An AI playing
  Black makes exactly one opening move when a match starts or restarts.
- AI-vs-AI games never advance automatically. The board is read-only and each
  explicit `Next step` action commits exactly one AI move.
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
  deleted, Social/search/stats records are removed, and retained history is
  anonymized without changing the opponent's historical aggregate result.
- Privacy Policy, Terms of Use, open-source licenses, and account-deletion
  guidance are reachable in the app without an online match.

## Online play

- A user can create a match and share a short join code.
- A second user can join by code or both can use quick match.
- Players receive opposite colors and Black moves first.
- The service rejects moves by spectators, moves on the wrong turn, occupied
  coordinates, stale revisions, and duplicate commands.
- A successful command atomically persists the snapshot and append-only move.
- The match snapshot retains the latest committed move coordinate so both
  players see the same last-move shutter after polling or reopening the match.
- Polling returns `304 Not Modified` when the match version is unchanged.
- Both players can load the same replay and independently reproduce its final
  state hash.
- Resignation produces a terminal outcome and prevents future moves.
- Both players' public display names map to their randomly assigned colors in
  private and quick matches. Match documents contain no native usernames,
  provider-generated login identifiers, or email addresses, and account
  deletion replaces the departed player's stored name and identifier with
  `Deleted player`.
- Every active account remains discoverable. Player search finds any substring
  of a public display name or native login username after NFKC, case-folding,
  and whitespace normalization; accepts 1–48 characters; and is capped and
  rate-limited. Search, friend, request, and challenge summaries show a native
  username as an `@` handle when present. Emails and Google/provider-generated
  login identifiers are not searchable or returned. The legacy privacy
  endpoint cannot hide an account.
- Native handles never enter match, matchmaking, or notification documents;
  accepted friend challenges snapshot only the public display name into the
  resulting match.
- JPEG, PNG, and WebP profile-picture uploads are authenticated, rate-limited,
  strictly validated, metadata-stripped, fixed-square re-encoded, and published
  only from private storage through an exact-version public route. Search, Social,
  challenges, and current match responses show the current version; stale versions
  return `404`. Account deletion immediately fences delivery, attempts synchronous
  private cleanup, and leaves any racing/failed object pending or orphaned for the
  authoritative cleanup worker and lifecycle fallback.
- Friend requests are race-safe and idempotent; either friend can unfriend. A
  direct challenge is visible only to the two friends, expires after seven days,
  has no join code, and retrying acceptance returns the same active match ID.
- Every private, quick, and accepted friend-challenge match is rated. Local games
  are neither uploaded nor rated. Accepted moves update each player's visible total
  kills and total spawns while the game is still active. A terminal result updates
  both ratings and games/wins/losses/draws plus finalized kill/spawn storage exactly
  once without changing the already-visible totals; rating deltas sum to zero.
- Each Black-cell death credits White and each White-cell death credits Black,
  regardless of mover or prior contribution.
- Every evolution birth credits the player whose color is born, regardless of mover;
  manual placement is never counted as a spawn.
- After OS/browser permission is granted, sign-in automatically registers turn
  notifications. Scheduled reminders contain no player identity, stale jobs send
  nothing, and sign-out/account deletion unregister the installation.

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

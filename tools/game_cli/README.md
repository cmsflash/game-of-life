# game_cli

Streaming JSON Lines interface to `game_engine`. It is intended for the
authoritative backend, scripts, replay verification, and AI environments.

```sh
dart run bin/game_cli.dart --jsonl
```

The default mode is also JSONL. `--once` processes the first non-empty input
line and exits, which is convenient for Lambda-style process invocation.

Every input line is one JSON object using `op`.
Every output is exactly one of:

```json
{"ok":true,"result":{}}
{"ok":false,"error":{"code":"occupied","message":"..."}}
```

## Operations

Create the standard initial position:

```json
{"op":"initial"}
```

Apply an authoritative move:

```json
{
  "op":"applyMove",
  "state": {"...":"state returned by initial"},
  "move": {
    "player":"black",
    "row":0,
    "column":0,
    "expectedRevision":0
  }
}
```

Other operations are:

- `evolve`: accepts `board` with `rows`, `columns`, and row-major `cells`, plus
  the required `player` (`black` or `white`).
- `legalMoves`: accepts `state` and returns every empty coordinate.
- `replay`: accepts optional `rules` or `initialState` and a `moves` array.
  Replay moves may omit player and revision; the CLI deterministically fills
  them from the current state.

The accepted operation names are `initial`, `applyMove`, `evolve`,
`legalMoves`, and `replay`.

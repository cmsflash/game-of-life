# Local AI feature design

## Scope

The product supports two local AI levels, both based only on living-cell
difference:

1. **AI level 1** maximizes its own cells minus the opponent's cells after its
   move and the resulting evolution.
2. **AI level 2** searches one move further. It chooses the first move whose
   worst legal opponent reply leaves the largest cell difference.

The app, the headless AI package, and offline experiments all use the shared
deterministic `game_engine`. The AI package has no Flutter, product-service,
network, persistence, or clock dependency.

The former Max own cells, Min their cells, percentage-mixture, adaptive
optimizer, and representative-tournament APIs are no longer supported.
Completed reports under `docs/experiments` remain as historical research.

## AI level 1

`OneStepMaxDifferenceAgent` applies every legal move through the canonical
engine. Moves that produce equal successor states are grouped and evaluated
once. The agent chooses the unique successor with the largest
own-minus-opponent population and uses the first row-major coordinate by
default when scores tie.

## AI level 2

`TwoStepMaxDifferenceAgent` evaluates every unique first-move successor against
every legal opponent reply. The first move receives the smallest population
difference produced by any reply. The agent selects the move with the largest
such worst-case value, making this a two-ply maximin search.

A first move that ends the game is evaluated immediately because it has no
opponent reply. Seeded SHA-256 tie-breaking is available for reproducible
headless trials and only varies the choice among equal best successors.

## Product configuration

Local setup supports human vs human, player vs AI with either human color, and
AI vs AI. Player vs AI has one level selector. AI vs AI has independent Black
and White selectors, allowing level 1 versus level 2 in either color order.

- In player vs AI, the AI responds exactly once after a confirmed human move.
  If the AI is Black, it makes exactly one opening move when the match is
  created or restarted.
- In AI vs AI, the board is read-only and no turn runs automatically. Each
  press of **Next step** computes, saves, and displays exactly one AI move.

## Persistence and compatibility

Each color's persisted participant type is `human`, `aiLevel1`, or `aiLevel2`.
Saved participant type `ai` from the previous release maps to `aiLevel1`.
Obsolete strategy percentages in an old save are ignored and are not written
back. Saves that predate participant fields still load as human vs human.

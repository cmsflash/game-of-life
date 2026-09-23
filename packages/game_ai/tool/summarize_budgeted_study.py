#!/usr/bin/env python3
"""Summarize strict-budget tournaments without treating censored games as draws.

Usage: python3 tool/summarize_budgeted_study.py STUDY_DIR [...] --output=report.md
JSON is always written to stdout. Each study is reported separately; studies are
never pooled across budgets, source revisions, or seed sets.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import sys


RUNNER_VERSION = "budgetedSearchTournamentV1"
CONFIG_KEYS = {
    "studyId", "sourceRevision", "evaluationVersion", "baseSeed", "gamesPerCell",
    "safetyMaxPlies", "transitionBudget", "profiles", "pairings",
}
COUNTERS = (
    "successorEvaluations", "nodesVisited", "cacheHits", "cutoffs",
    "elapsedMicroseconds",
)
CAVEATS = [
    "All games use the same centered 2x2 diagonal opening and elimination rules. "
    "Only tie-breaking seeds vary; this does not establish strength across varied openings.",
    "The budget is a per-move ceiling on generated unique successors, not equal actual "
    "work or equal time. Shallow searches can stop early. Runtime also depends on "
    "machine load; transitions exclude some hashing and duplicate-generation overhead.",
    "Full-width early plies followed by a beam are selective search. A winning score "
    "from that search is not a full-game proof. Completed horizon is the completed "
    "requested horizon, not actual search reach: terminal branches stop earlier. "
    "Max visited ply includes work from any partially completed deeper iteration.",
    "Truncated games are right-censored at the safety cap, not draws. Active, error, "
    "and not-started games are separate. Win/score bounds allow every unresolved game "
    "to become a loss or win; completed-only rates can be biased by game length.",
    "Lengths use plies (one player's move). Completed-game lengths exclude unfinished "
    "games. Percentiles use nearest rank; medians use the usual middle-value average.",
    "Per-profile win records exclude self-play and depend on the opponent schedule. "
    "Per-turn diagnostics include every recorded move, including self-play and unfinished games.",
    "Seeds are reused across pairings and colors have distinct seeds. Shared seed trials can correlate outcomes; "
    "nominal Wilson intervals are descriptive, not paired or cluster-adjusted inference. "
    "Small screening samples and selecting a winner require fresh-seed confirmation.",
    "D1/D2 denote experiment profiles, not guaranteed identical app behavior: hard-budget "
    "fallback and tie-breaking can differ. Multiple input studies are shown separately, not pooled.",
    "During a live run, each game is read from its latest atomic checkpoint, not a "
    "single synchronized tournament instant. Checkpoints are saved every 25 plies "
    "and can lag the live positions.",
]


class ValidationError(ValueError):
    """A study cannot be safely interpreted."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def integer(value, label, minimum=0, maximum=None):
    require(type(value) is int and value >= minimum and
            (maximum is None or value <= maximum), f"invalid {label}: {value!r}")
    return value


def read_object(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ValidationError(f"{path}: {error}") from error
    require(isinstance(value, dict), f"{path}: expected JSON object")
    return value


def config_digest(config):
    normalized = {key: config[key] for key in CONFIG_KEYS}
    canonical = json.dumps(normalized, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def validate_config(config):
    require(set(config) == CONFIG_KEYS | {"runnerVersion", "configHash"},
            "config.json does not have the runner's normalized fields")
    require(config["runnerVersion"] == RUNNER_VERSION, "unsupported runner version")
    require(config["evaluationVersion"] == "terminalUtilityV1",
            "unsupported evaluation version")
    for key in ("studyId", "sourceRevision"):
        require(isinstance(config[key], str) and config[key].strip(), f"invalid {key}")
    for key in ("baseSeed", "gamesPerCell", "safetyMaxPlies", "transitionBudget"):
        integer(config[key], key, 0 if key == "baseSeed" else 400 if key == "transitionBudget" else 1)
    profiles = {}
    require(isinstance(config["profiles"], list) and config["profiles"], "no profiles")
    for profile in config["profiles"]:
        require(isinstance(profile, dict) and set(profile) ==
                {"id", "maxDepth", "fullWidthDepth", "beamWidth"}, "invalid profile")
        name = profile["id"]
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", name)
                and "__" not in name and name not in profiles, "invalid/duplicate profile ID")
        for key in ("maxDepth", "fullWidthDepth", "beamWidth"):
            integer(profile[key], key, 1, 400 if key == "beamWidth" else 64)
        profiles[name] = profile
    pairs = []
    require(isinstance(config["pairings"], list) and config["pairings"], "no pairings")
    for pair in config["pairings"]:
        require(isinstance(pair, dict) and set(pair) == {"black", "white"}, "invalid pairing")
        key = (pair["black"], pair["white"])
        require(all(name in profiles for name in key) and key not in pairs,
                "unknown profile or duplicate pairing")
        pairs.append(key)
    require(config["configHash"] == config_digest(config), "config hash mismatch")
    return profiles, pairs


def identity(config, black, white, trial):
    return {
        **{key: config[key] for key in ("runnerVersion", "studyId", "sourceRevision",
                                       "evaluationVersion", "configHash")},
        "blackProfile": black, "whiteProfile": white, "trial": trial,
        "blackTieBreakSeed": config["baseSeed"] + 2 * trial,
        "whiteTieBreakSeed": config["baseSeed"] + 2 * trial + 1,
    }


def game_key(game):
    return (game.get("blackProfile"), game.get("whiteProfile"), game.get("trial"))


def validate_saved_state(game, plies):
    """Check report-driving JSON fields; canonical move replay stays in Dart."""
    require({"winner", "outcomeReason", "blackPopulation", "whitePopulation", "state"} <= game.keys(),
            "missing game outcome/state fields")
    state = game["state"]
    require(isinstance(state, dict) and
            {"cells", "ply", "revision", "toMove", "status", "outcome"} <= state.keys(),
            "missing saved state fields")
    for key in ("ply", "revision"):
        require(integer(state[key], f"state.{key}") == plies, "state/game ply mismatch")
    cells = state["cells"]
    require(isinstance(cells, list) and len(cells) == 400 and
            all(type(value) is int and value in (0, 1, 2) for value in cells),
            "invalid saved state cells")
    populations = {"blackPopulation": cells.count(1), "whitePopulation": cells.count(2)}
    for key, value in populations.items():
        require(integer(game[key], key, maximum=400) == value, "state/game population mismatch")
    outcome = state["outcome"]
    require(game["complete"] == (outcome is not None), "state/game completion mismatch")
    require(state["status"] == ("completed" if game["complete"] else "active"),
            "state status/completion mismatch")
    require(state["toMove"] == (None if game["complete"] else "black" if plies % 2 == 0 else "white"),
            "state toMove/completion mismatch")
    if outcome is None:
        require(game["winner"] is None and game["outcomeReason"] is None,
                "active state has terminal game outcome")
        return
    require(isinstance(outcome, dict) and set(outcome) ==
            {"type", "winner", "reason", "blackPopulation", "whitePopulation"},
            "invalid saved state outcome")
    require(outcome["type"] in {"win", "draw"} and
            ((outcome["type"] == "win" and outcome["winner"] in {"black", "white"}) or
             (outcome["type"] == "draw" and outcome["winner"] is None)),
            "invalid saved state outcome type/winner")
    require(game["winner"] == outcome["winner"] and game["outcomeReason"] == outcome["reason"],
            "state/game outcome mismatch")
    for key, value in populations.items():
        require(integer(outcome[key], f"outcome.{key}", maximum=400) == value,
                "state/outcome population mismatch")


def validate_game(game, expected, config, profiles):
    for key, value in expected.items():
        require(game.get(key) == value and type(game.get(key)) is type(value),
                f"game identity mismatch: {key}")
    status = game.get("status")
    require(status in {"complete", "truncated", "active", "error"}, "invalid game status")
    plies = integer(game.get("plies"), "plies", maximum=config["safetyMaxPlies"])
    moves = game.get("moves")
    require(isinstance(moves, list) and len(moves) == plies, "plies/history mismatch")
    require(type(game.get("complete")) is bool and type(game.get("truncated")) is bool,
            "missing completion flags")
    require(not (game["complete"] and game["truncated"]), "complete and truncated")
    if status != "error":
        require(game["complete"] == (status == "complete") and
                game["truncated"] == (status == "truncated"), "status/flags mismatch")
    require(game.get("winner") in {None, "black", "white"}, "invalid winner")
    require(game["complete"] or game.get("winner") is None, "unfinished game has winner")
    require(game["complete"] or game.get("outcomeReason") is None,
            "unfinished game has terminal reason")
    require(not game["complete"] or isinstance(game.get("outcomeReason"), str),
            "completed game has no terminal reason")
    require(game["truncated"] == (not game["complete"] and plies >= config["safetyMaxPlies"]),
            "truncation/cap mismatch")
    validate_saved_state(game, plies)
    totals = Counter()
    depths = Counter()
    for index, move in enumerate(moves):
        require(isinstance(move, dict), "invalid move")
        player = "black" if index % 2 == 0 else "white"
        require(move.get("player") == player, "move players do not alternate")
        for key in ("row", "column"):
            integer(move.get(key), key, maximum=19)
        profile = profiles[expected[f"{player}Profile"]]
        depth = integer(move.get("completedDepth"), "completedDepth", 1, profile["maxDepth"])
        integer(move.get("attemptedDepth"), "attemptedDepth", depth, profile["maxDepth"])
        integer(move.get("maxVisitedPly"), "maxVisitedPly", 1, move["attemptedDepth"])
        for key in COUNTERS:
            maximum = config["transitionBudget"] if key == "successorEvaluations" else None
            totals[key] += integer(move.get(key), key, maximum=maximum)
        require(type(move.get("budgetExhausted")) is bool, "invalid budgetExhausted")
        require(not move["budgetExhausted"] or
                move["successorEvaluations"] == config["transitionBudget"],
                "exhausted move did not consume its transition budget")
        totals["budgetExhaustedMoves"] += move["budgetExhausted"]
        depths[str(depth)] += 1
    totals["moves"] = plies
    expected_totals = {key: totals[key] for key in (*COUNTERS, "moves", "budgetExhaustedMoves")}
    expected_totals["maxVisitedPly"] = max((move["maxVisitedPly"] for move in moves), default=0)
    expected_totals["completedDepthHistogram"] = dict(depths)
    require(game.get("searchTotals") == expected_totals, "searchTotals/history mismatch")


def distribution(values):
    values = sorted(values)
    if not values:
        return {"n": 0, "total": 0, "mean": None, "median": None, "p90": None,
                "p95": None, "min": None, "max": None}
    return {
        "n": len(values), "total": sum(values), "mean": statistics.mean(values),
        "median": statistics.median(values),
        "p90": values[math.ceil(len(values) * .9) - 1],
        "p95": values[math.ceil(len(values) * .95) - 1],
        "min": values[0], "max": values[-1],
    }


def wilson(wins, n):
    if not n:
        return None
    z = 1.959963984540054
    fraction = wins / n
    divisor = 1 + z * z / n
    center = (fraction + z * z / (2 * n)) / divisor
    radius = z * math.sqrt(fraction * (1 - fraction) / n + z * z / (4 * n * n)) / divisor
    return [max(0, center - radius), min(1, center + radius)]


def outcomes(games, perspective, perspective_is_color=False):
    """Perspective is a color or a profile ID (only valid outside self-play)."""
    counts = Counter(game["status"] for game in games)
    wins = losses = draws = 0
    for game in games:
        if game["status"] != "complete":
            continue
        color = perspective if perspective_is_color else (
            "black" if game["blackProfile"] == perspective else "white")
        if game.get("winner") is None:
            draws += 1
        elif game["winner"] == color:
            wins += 1
        else:
            losses += 1
    completed = wins + losses + draws
    n = len(games)
    unresolved = n - completed
    score = wins + .5 * draws
    return {
        "plannedGames": n, "completed": completed, "wins": wins, "losses": losses,
        "draws": draws, "unfinished": unresolved,
        **{key: counts[key] for key in ("truncated", "active", "error", "notStarted")},
        "winRate": wins / n if n and not unresolved else None,
        "completedOnlyWinRate": wins / completed if completed else None,
        "winRateBounds": [wins / n, (wins + unresolved) / n] if n else None,
        "scoreRate": score / n if n and not unresolved else None,
        "scoreRateBounds": [score / n, (score + unresolved) / n] if n else None,
        "nominalWilson95WinRate": wilson(wins, n) if not unresolved else None,
        "completedLengthPlies": distribution([g["plies"] for g in games if g["status"] == "complete"]),
        "truncatedObservedPlies": distribution([g["plies"] for g in games if g["status"] == "truncated"]),
        "activeObservedPlies": distribution([g["plies"] for g in games if g["status"] == "active"]),
        "errorObservedPlies": distribution([g["plies"] for g in games if g["status"] == "error" and "plies" in g]),
    }


def search_stats(moves, budget):
    depths = Counter(move["completedDepth"] for move in moves)
    n = len(moves)
    successors = distribution([move["successorEvaluations"] for move in moves])
    return {
        "moves": n,
        "successorEvaluations": successors,
        "meanBudgetFraction": successors["mean"] / budget if n else None,
        "elapsedMilliseconds": distribution([move["elapsedMicroseconds"] / 1000 for move in moves]),
        "completedDepthHistogram": {str(key): depths[key] for key in sorted(depths)},
        "completedDepth": distribution([move["completedDepth"] for move in moves]),
        "maxVisitedPly": distribution([move["maxVisitedPly"] for move in moves]),
        "shareDepthAtLeast4": sum(count for depth, count in depths.items() if depth >= 4) / n if n else None,
        "shareDepthAtLeast5": sum(count for depth, count in depths.items() if depth >= 5) / n if n else None,
        "budgetExhaustedMoves": sum(move["budgetExhausted"] for move in moves),
        "totalNodesVisited": sum(move["nodesVisited"] for move in moves),
        "totalCacheHits": sum(move["cacheHits"] for move in moves),
        "totalCutoffs": sum(move["cutoffs"] for move in moves),
    }


def summarize_study(directory):
    directory = Path(directory).resolve()
    config = read_object(directory / "config.json")
    profiles, pairs = validate_config(config)
    expected = {
        (black, white, trial): identity(config, black, white, trial)
        for black, white in pairs for trial in range(config["gamesPerCell"])
    }
    games = {}

    def load_checkpoint(path, key, game=None):
        if game is None:
            game = read_object(path)
        require(game_key(game) == key, f"{path}: filename/identity mismatch")
        try:
            validate_game(game, expected[key], config, profiles)
        except ValidationError as error:
            raise ValidationError(f"{path}: {error}") from error
        games[key] = game

    for path in sorted((directory / "games").glob("*.json")):
        game = read_object(path)
        key = game_key(game)
        require(key in expected, f"{path}: unexpected game identity")
        require(key not in games, f"{path}: duplicate game identity")
        require(path.name == f"{key[0]}__{key[1]}__{key[2]}.json", f"{path}: filename/identity mismatch")
        load_checkpoint(path, key, game)
    # A summary read after directory discovery can reference a newly created
    # checkpoint. Load that specific path once before declaring it missing.
    # Existing checkpoint snapshots still take precedence over summary entries.
    summary_path = directory / "summary.json"
    if summary_path.exists():
        summary = read_object(summary_path)
        for key in ("runnerVersion", "studyId", "sourceRevision", "evaluationVersion", "configHash"):
            require(summary.get(key) == config[key], f"summary identity mismatch: {key}")
        require(isinstance(summary.get("games"), list), "summary has no games list")
        seen = set()
        for compact in summary["games"]:
            require(isinstance(compact, dict), "invalid compact game")
            key = game_key(compact)
            require(key in expected and key not in seen, "unexpected/duplicate summary game")
            seen.add(key)
            for field, value in expected[key].items():
                require(compact.get(field) == value, f"summary game identity mismatch: {field}")
            if key not in games:
                path = directory / "games" / f"{key[0]}__{key[1]}__{key[2]}.json"
                if path.exists():
                    load_checkpoint(path, key)
                else:
                    require(compact.get("status") == "error" and "plies" not in compact,
                            "summary records a game whose checkpoint is missing")
                    games[key] = {**compact, "moves": []}
    all_games = [games.get(key, {**value, "status": "notStarted", "moves": []})
                 for key, value in expected.items()]
    pair_results = [
        {"black": black, "white": white, **outcomes(
            [game for game in all_games if game_key(game)[:2] == (black, white)], "black", True)}
        for black, white in pairs
    ]
    profile_results = []
    for name, profile in profiles.items():
        crossplay = [g for g in all_games if name in game_key(g)[:2]
                     and g["blackProfile"] != g["whiteProfile"]]
        moves = [move for game in all_games for move in game["moves"]
                 if game[f"{move['player']}Profile"] == name]
        reference = [g for g in crossplay if "D2" in game_key(g)[:2]] if name != "D2" else []
        profile_results.append({
            **profile, "crossplay": outcomes(crossplay, name),
            "crossplayByColor": {color: outcomes([g for g in crossplay if g[f"{color}Profile"] == name], name)
                                 for color in ("black", "white")},
            "versusD2": outcomes(reference, name) if reference else None,
            "search": search_stats(moves, config["transitionBudget"]),
        })
    longest = {}
    for status in ("complete", "truncated", "active", "error"):
        candidates = [g for g in all_games if g["status"] == status and "plies" in g]
        longest[status] = [
            {key: g.get(key) for key in ("blackProfile", "whiteProfile", "trial", "plies",
                                         "blackTieBreakSeed", "whiteTieBreakSeed", "winner", "outcomeReason")}
            for g in candidates if g["plies"] == max(item["plies"] for item in candidates)
        ]
    return {
        "directory": str(directory), "config": config,
        "opening": "centered2x2Diagonal", "victoryRule": "elimination",
        "budgetMetric": "generatedUniqueSuccessors", "overallBlack": outcomes(all_games, "black", True),
        "pairs": pair_results, "profiles": profile_results, "longestGames": longest,
    }


def summarize(directories):
    studies = []
    paths = set()
    hashes = set()
    for directory in directories:
        path = Path(directory).resolve()
        if path in paths:
            continue
        paths.add(path)
        study = summarize_study(path)
        digest = study["config"]["configHash"]
        require(digest not in hashes, "two directories contain the same study config; pass only one copy")
        hashes.add(digest)
        studies.append(study)
    return {"reportVersion": 1, "snapshotUtc": datetime.now(timezone.utc).isoformat(),
            "studies": studies, "caveats": CAVEATS}


def cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def number(value):
    return "—" if value is None else f"{value:,.2f}".rstrip("0").rstrip(".")


def percent(value):
    if value is None:
        return "—"
    if 0 < value < .001:
        return "<0.1%"
    if .999 < value < 1:
        return ">99.9%"
    return f"{100 * value:.1f}%"


def bounds(value):
    return "—" if value is None else f"{percent(value[0])}–{percent(value[1])}"


def rate(result):
    if not result["plannedGames"]:
        return "—"
    if result["winRate"] is not None:
        return percent(result["winRate"])
    return f"{bounds(result['winRateBounds'])} (bounds)"


def table(headers, rows):
    return ["| " + " | ".join(map(cell, headers)) + " |",
            "| " + " | ".join("---" for _ in headers) + " |",
            *["| " + " | ".join(map(cell, row)) + " |" for row in rows], ""]


def render_markdown(report):
    interim = any(any(study["overallBlack"][key] for key in ("active", "error", "notStarted"))
                  for study in report["studies"])
    title = "# Budget-controlled AI experiments" + (" — interim snapshot" if interim else "")
    lines = [title, "", f"Snapshot (UTC): {report['snapshotUtc']}.", "",
             "Win rates mean wins / scheduled games, with draws counted as non-wins. "
             "Bounds replace point estimates whenever games are unresolved. "
             "Each color-specific cell is reported independently.", ""]
    for study_index, study in enumerate(report["studies"], 1):
        config = study["config"]
        overall = study["overallBlack"]
        lines += [f"## {study_index}. {cell(config['studyId'])}", "",
                  f"Source revision: `{config['sourceRevision']}`; evaluation: `{config['evaluationVersion']}`. "
                  f"Budget: **{config['transitionBudget']:,} unique successors/move**; "
                  f"safety cap: {config['safetyMaxPlies']:,} plies; base seed: {config['baseSeed']}.", "",
                  f"{overall['completed']}/{overall['plannedGames']} games completed; "
                  f"{overall['truncated']} truncated, {overall['active']} active, "
                  f"{overall['error']} errored, {overall['notStarted']} not started.", "",
                  f"Config hash: `{config['configHash']}`. Data: `{study['directory']}`.", "",
                  "### Matchups (Black's perspective)", ""]
        lines += table(["ID", "Black", "White", "W–L–D", "Unfinished (cap/active/error/new)",
                        "Black win rate", "Completed-only win rate", "Finished length mean / median / p90 / max"], [
            [f"M{i}", pair["black"], pair["white"], f"{pair['wins']}–{pair['losses']}–{pair['draws']}",
             f"{pair['unfinished']} ({pair['truncated']}/{pair['active']}/{pair['error']}/{pair['notStarted']})",
             rate(pair), percent(pair["completedOnlyWinRate"]),
             " / ".join(number(pair["completedLengthPlies"][key]) for key in ("mean", "median", "p90", "max"))]
            for i, pair in enumerate(study["pairs"], 1)])
        lines += ["### Profiles (cross-play only; no self-play outcomes)", ""]
        lines += table(["ID", "Max depth / full-width prefix / beam", "W–L–D / unfinished", "Win rate",
                        "Black W–L–D", "White W–L–D"], [
            [profile["id"], f"{profile['maxDepth']} / {profile['fullWidthDepth']} / {profile['beamWidth']}",
             f"{profile['crossplay']['wins']}–{profile['crossplay']['losses']}–{profile['crossplay']['draws']} / {profile['crossplay']['unfinished']}",
             rate(profile["crossplay"]),
             *["–".join(str(profile["crossplayByColor"][color][key]) for key in ("wins", "losses", "draws"))
               for color in ("black", "white")]] for profile in study["profiles"]])
        lines += ["### Actual search effort (all recorded turns)", ""]
        lines += table(["ID", "Turns", "Transitions mean / p95 / max", "Mean budget used",
                        "Time ms mean / p50 / p95 / max", "Completed horizon counts", "Horizon ≥4 / ≥5",
                        "Max visited ply mean / max"], [
            [profile["id"], profile["search"]["moves"],
             " / ".join(number(profile["search"]["successorEvaluations"][key]) for key in ("mean", "p95", "max")),
             percent(profile["search"]["meanBudgetFraction"]),
             " / ".join(number(profile["search"]["elapsedMilliseconds"][key]) for key in ("mean", "median", "p95", "max")),
             ", ".join(f"{depth}: {count}" for depth, count in profile["search"]["completedDepthHistogram"].items()) or "—",
             f"{percent(profile['search']['shareDepthAtLeast4'])} / {percent(profile['search']['shareDepthAtLeast5'])}",
             " / ".join(number(profile["search"]["maxVisitedPly"][key]) for key in ("mean", "max"))]
            for profile in study["profiles"]])
        references = [p for p in study["profiles"] if p["versusD2"]]
        if references:
            lines += ["### Versus D2 (both scheduled colors)", ""]
            lines += table(["ID", "W–L–D / unfinished", "Win rate", "Nominal Wilson 95%"], [
                [p["id"], f"{p['versusD2']['wins']}–{p['versusD2']['losses']}–{p['versusD2']['draws']} / {p['versusD2']['unfinished']}",
                 rate(p["versusD2"]), bounds(p["versusD2"]["nominalWilson95WinRate"])] for p in references])
        lines += ["### Longest observed games (ties retained)", ""]
        lines += table(["ID", "Status", "Black", "White", "Trial", "Plies", "Black seed / White seed", "Outcome"], [
            [f"L{i}", status, g["blackProfile"], g["whiteProfile"], g["trial"], g["plies"],
             f"{g['blackTieBreakSeed']} / {g['whiteTieBreakSeed']}",
             f"{g['winner'] or 'draw'}: {g['outcomeReason']}" if status == "complete" else "unresolved"]
            for i, (status, g) in enumerate(((status, g) for status, games in study["longestGames"].items() for g in games), 1)])
    lines += ["## Interpretation limits", "", *[f"- {caveat}" for caveat in report["caveats"]], ""]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("study_dirs", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, help="optional Markdown report path")
    args = parser.parse_args(argv)
    try:
        report = summarize(args.study_dirs)
        if args.output:
            args.output.write_text(render_markdown(report), encoding="utf-8")
        print(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False))
    except (ValidationError, OSError) as error:
        parser.exit(2, f"error: {error}\n")


if __name__ == "__main__":
    main()

"""Validate and report the final D3/F1B4/F2B8 round robin.

Usage: python3 report_round_robin.py STUDY [--output REPORT.md] [--json RESULTS.json]
Run from the repository, or pass its path with --repo.
"""
import argparse
from collections import Counter
from itertools import combinations, permutations
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
POLICIES = {"D3": (3, 64, 8), "F1B4": (8, 1, 4), "F2B8": (8, 2, 8)}
CAP = 20_000
BASE_SEED = 6_100_000
RULES_HASH = "738d769985f317b342deb3e85c758ff827030ff4c3880a564089b07c6f68aa60"


def read_games(study, validator):
    config = validator.read_object(study / "config.json")
    profiles, pairs = validator.validate_config(config)
    require = validator.require
    require(config["baseSeed"] == BASE_SEED and config["gamesPerCell"] == 10,
            "expected ten fresh seed pairs starting at 6100000")
    require(config["safetyMaxPlies"] == CAP and config["transitionBudget"] == 100_000,
            "unexpected per-game cap or per-move budget")
    require({name: (p["maxDepth"], p["fullWidthDepth"], p["beamWidth"])
             for name, p in profiles.items()} == POLICIES, "unexpected search profiles")
    require(set(pairs) == set(permutations(POLICIES, 2)), "expected all six distinct color orders")
    expected = {(black, white, trial) for black, white in pairs for trial in range(10)}
    paths = {path.name for path in (study / "games").glob("*.json")}
    require(paths == {f"{b}__{w}__{t}.json" for b, w, t in expected},
            "final review requires all 60 scheduled checkpoints")
    games, turns, work, elapsed = {}, Counter(), Counter(), Counter()
    for black, white, trial in sorted(expected):
        path = study / "games" / f"{black}__{white}__{trial}.json"
        g = validator.read_object(path)
        validator.validate_game(g, validator.identity(config, black, white, trial), config, profiles)
        require(g["status"] == "complete" or (g["status"] == "truncated" and g["plies"] == CAP),
                f"{path.name} has not ended naturally or reached 20,000")
        state = g["state"]
        require(state["rulesHash"] == RULES_HASH, f"unexpected rules in {path.name}")
        pops = (g["blackPopulation"], g["whitePopulation"])
        reason, winner = None, None
        if pops == (0, 0):
            reason = "mutualExtinction"
        elif 0 in pops:
            reason, winner = "elimination", ("black" if pops[0] else "white")
        elif sum(pops) == 400:
            reason = "noLegalMoves"
        require((reason, winner) == (g["outcomeReason"], g["winner"]),
                f"saved board/outcome mismatch in {path.name}")
        for move in g.pop("moves"):
            name = black if move["player"] == "black" else white
            turns[name] += 1
            work[name] += move["successorEvaluations"]
            elapsed[name] += move["elapsedMicroseconds"]
        games[black, white, trial] = {
            k: g[k] for k in ("blackProfile", "whiteProfile", "trial", "blackTieBreakSeed",
                              "whiteTieBreakSeed", "status", "winner", "outcomeReason", "plies")
        }
    search = {
        name: dict(moves=turns[name], meanSuccessors=work[name] / turns[name],
                   meanMilliseconds=elapsed[name] / turns[name] / 1000)
        for name in POLICIES
    }
    return config, games, search


def outcome(game, policy):
    if game["status"] == "truncated":
        return "U"
    if game["winner"] is None:
        return "D"
    return "W" if game[game["winner"] + "Profile"] == policy else "L"


def record(games, policy):
    counts = Counter(outcome(g, policy) for g in games)
    points = counts["W"] + counts["D"] / 2
    return {**{key: counts[key] for key in "WLDU"}, "games": len(games),
            "scoreBounds": [points, points + counts["U"]]}


def summarize(config, games, search):
    policies, matchups = {}, {}
    all_games = list(games.values())
    for name in POLICIES:
        played = [g for g in all_games if name in (g["blackProfile"], g["whiteProfile"])]
        policies[name] = dict(overall=record(played, name), search=search[name])
        for color in ("black", "white"):
            policies[name][color] = record([g for g in played if g[color + "Profile"] == name], name)
    for a, b in combinations(POLICIES, 2):
        black = [games[a, b, trial] for trial in range(10)]
        white = [games[b, a, trial] for trial in range(10)]
        by_seed = [outcome(g, a) + outcome(h, a) for g, h in zip(black, white, strict=True)]
        matchups[f"{a} / {b}"] = dict(first=a, second=b, record=record(black + white, a),
                                      asBlack=record(black, a), asWhite=record(white, a),
                                      bySeed=by_seed, patternCounts=dict(Counter(by_seed)))
    return dict(studyId=config["studyId"], configHash=config["configHash"], baseSeed=BASE_SEED,
                cap=CAP, plies=sum(g["plies"] for g in all_games),
                blackWins=sum(g["winner"] == "black" for g in all_games),
                whiteWins=sum(g["winner"] == "white" for g in all_games),
                naturalDraws=sum(g["status"] == "complete" and g["winner"] is None for g in all_games),
                capped=sum(g["status"] == "truncated" for g in all_games),
                policies=policies, matchups=matchups, games=all_games)


def score_text(row):
    lo, hi = row["scoreBounds"]
    return (f"{lo:g}" if lo == hi else f"{lo:g}–{hi:g}") + f" / {row['games']}"


def record_text(row):
    return " / ".join(str(row[key]) for key in "WLDU")


def render(data):
    lines = ["# Game of Life AI three-way round robin", "",
             f"The 60 games produced {data['blackWins']} Black wins, {data['whiteWins']} White wins, "
             f"{data['naturalDraws']} natural draw{'' if data['naturalDraws'] == 1 else 's'} and {data['capped']} unfinished games at 20,000 moves. "
             f"The players made {data['plies']:,} moves.", "",
             "Each matchup used the same ten fresh pairs of tie-breaking seeds and the centered diagonal opening. "
             "The policies swapped colors for the second game of each pair. A win earns one point and a draw earns half. "
             "The score ranges show how many points each policy could earn if the capped games were continued.", "",
             "| ID | Wins | Losses | Draws | Capped | Possible score |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for name, policy in data["policies"].items():
        r = policy["overall"]
        lines.append(f"| {name} | {r['W']} | {r['L']} | {r['D']} | {r['U']} | {score_text(r)} |")
    lines += ["", "## Head-to-head results", "",
              "Each row gives the first policy's record against the second. The color columns show "
              "wins, losses, draws and capped games in that order.", "",
              "| ID | First policy | Second policy | First wins | Second wins | Draws | Capped | First as Black | First as White | First's possible score |",
              "| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- | ---: |"]
    for i, m in enumerate(data["matchups"].values(), 1):
        r = m["record"]
        lines.append(f"| M{i} | {m['first']} | {m['second']} | {r['W']} | {r['L']} | {r['D']} | {r['U']} "
                     f"| {record_text(m['asBlack'])} | {record_text(m['asWhite'])} | {score_text(r)} |")
    lines += ["", "## Matched seed pairs", "",
              "A sweep means the same policy won in both colors. A split means the policies won one game each. "
              "A pair with either game still unresolved counts as capped.", "",
              "| ID | Matchup | First swept | Split | Second swept | Fully resolved with a draw | Capped pairs |",
              "| --- | --- | ---: | ---: | ---: | ---: | ---: |"]
    for index, (label, pair) in enumerate(data["matchups"].items(), 1):
        patterns = Counter(pair["bySeed"])
        capped = sum(count for pattern, count in patterns.items() if "U" in pattern)
        with_draw = sum(count for pattern, count in patterns.items() if "D" in pattern and "U" not in pattern)
        lines.append(f"| M{index} | {label} | {patterns['WW']} | {patterns['WL'] + patterns['LW']} "
                     f"| {patterns['LL']} | {with_draw} | {capped} |")
    lines += ["",
              "Each cell gives the first policy's result as Black, then as White. "
              "W means win, L loss, D draw and U unfinished at the cap. The Black and White seeds stay with their colors.", "",
              "| Pair ID | Black / White seed | " + " | ".join(data["matchups"]) + " |",
              "| --- | --- | --- | --- | --- |"]
    for t in range(10):
        black_seed = BASE_SEED + 2 * t
        lines.append(f"| S{t + 1} | {black_seed} / {black_seed + 1} | " +
                     " | ".join(" / ".join(m["bySeed"][t]) for m in data["matchups"].values()) + " |")
    lines += ["", "## Search effort", "",
              "Every decision had a ceiling of 100,000 generated successor positions. "
              "Elapsed times combine two verified implementations and varying machine load.", "",
              "| ID | Decisions | Mean successors per decision | Mean milliseconds per decision |",
              "| --- | ---: | ---: | ---: |"]
    for name, policy in data["policies"].items():
        stats = policy["search"]
        lines.append(f"| {name} | {stats['moves']:,} | {stats['meanSuccessors']:,.2f} "
                     f"| {stats['meanMilliseconds']:,.2f} |")
    lines += ["", f"Study configuration SHA-256 `{data['configHash']}`.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("study", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(args.repo / "packages/game_ai/tool"))
    import summarize_budgeted_study as validator
    try:
        config, games, search = read_games(args.study, validator)
        report = summarize(config, games, search)
        markdown = render(report)
        if args.output:
            args.output.write_text(markdown, encoding="utf-8")
        else:
            print(markdown)
        if args.json:
            args.json.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    except (OSError, KeyError, ValueError) as error:
        parser.exit(1, f"Report refused: {error}\n")


if __name__ == "__main__":
    main()

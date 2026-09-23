"""Run with: python3 -m unittest discover -s packages/game_ai/tool -p 'test_*.py'."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import summarize_budgeted_study as report


def config(study_id="fixture", base_seed=6000000, games_per_cell=1, pairs=None):
    value = {
        "studyId": study_id, "sourceRevision": "test-source", "evaluationVersion": "terminalUtilityV1",
        "baseSeed": base_seed, "gamesPerCell": games_per_cell, "safetyMaxPlies": 10,
        "transitionBudget": 1000,
        "profiles": [{"id": name, "maxDepth": depth, "fullWidthDepth": 64, "beamWidth": 8}
                     for name, depth in [("D2", 2), ("D5", 5)]],
        "pairings": pairs or [{"black": "D2", "white": "D5"}, {"black": "D5", "white": "D2"}],
        "runnerVersion": report.RUNNER_VERSION,
    }
    value["configHash"] = report.config_digest(value)
    return value


def game(cfg, black="D2", white="D5", trial=0, status="complete", winner="black", plies=3):
    if status != "complete":
        winner = None
    moves = []
    profiles = {profile["id"]: profile for profile in cfg["profiles"]}
    for ply in range(plies):
        player = "black" if ply % 2 == 0 else "white"
        depth = profiles[black if player == "black" else white]["maxDepth"]
        moves.append({
            "player": player, "row": 0, "column": 0, "score": 0,
            "completedDepth": depth, "attemptedDepth": depth, "maxVisitedPly": 1,
            "successorEvaluations": 100 * (ply + 1), "nodesVisited": 10 * (ply + 1),
            "cacheHits": ply, "cutoffs": ply, "elapsedMicroseconds": 1000 * (ply + 1),
            "budgetExhausted": ply == 9,
        })
    totals = {key: sum(move[key] for move in moves) for key in report.COUNTERS}
    totals.update({"moves": plies, "budgetExhaustedMoves": sum(m["budgetExhausted"] for m in moves),
                   "maxVisitedPly": 1 if moves else 0,
                   "completedDepthHistogram": dict(report.Counter(str(m["completedDepth"]) for m in moves))})
    complete = status == "complete"
    cells = ([1] * 3 if winner == "black" else [2] * 3 if winner == "white" else []) if complete else [1, 1, 2, 2]
    cells += [0] * (400 - len(cells))
    populations = {"blackPopulation": cells.count(1), "whitePopulation": cells.count(2)}
    reason = ("elimination" if winner else "mutualExtinction") if complete else None
    outcome = {"type": "win" if winner else "draw", "winner": winner,
               "reason": reason, **populations} if complete else None
    return {
        **report.identity(cfg, black, white, trial),
        "status": status, "complete": complete, "truncated": status == "truncated",
        "plies": plies, "winner": winner,
        "outcomeReason": reason, **populations,
        "state": {"cells": cells, "ply": plies, "revision": plies,
                  "toMove": None if complete else "black" if plies % 2 == 0 else "white",
                  "status": "completed" if complete else "active", "outcome": outcome},
        "moves": moves, "searchTotals": totals,
    }


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write_study(self, cfg, games=(), name="study", summary_games=None):
        path = self.root / name
        (path / "games").mkdir(parents=True)
        (path / "config.json").write_text(json.dumps(cfg), encoding="utf-8")
        for item in games:
            key = report.game_key(item)
            (path / "games" / f"{key[0]}__{key[1]}__{key[2]}.json").write_text(json.dumps(item), encoding="utf-8")
        if summary_games is not None:
            summary = {key: cfg[key] for key in ("runnerVersion", "studyId", "sourceRevision", "evaluationVersion", "configHash")}
            summary["games"] = summary_games
            (path / "summary.json").write_text(json.dumps(summary), encoding="utf-8")
        return path

    def test_color_orientation_and_selfplay_exclusion(self):
        cfg = config(pairs=[{"black": "D2", "white": "D5"}, {"black": "D5", "white": "D2"},
                            {"black": "D5", "white": "D5"}])
        path = self.write_study(cfg, [game(cfg, winner="white"),
                                     game(cfg, black="D5", white="D2", winner="black", plies=4),
                                     game(cfg, black="D5", white="D5", winner="white", plies=2)])
        study = report.summarize_study(path)
        self.assertEqual(study["overallBlack"]["wins"], 1)
        self.assertEqual(study["overallBlack"]["losses"], 2)
        self.assertEqual(study["pairs"][0]["winRate"], 0)
        d5 = study["profiles"][1]
        self.assertEqual(d5["crossplay"]["wins"], 2)
        self.assertEqual(d5["crossplay"]["plannedGames"], 2)
        self.assertEqual(d5["crossplayByColor"]["white"]["wins"], 1)
        self.assertEqual(d5["versusD2"]["winRate"], 1)
        self.assertAlmostEqual(d5["versusD2"]["nominalWilson95WinRate"][0], .34238, places=4)
        self.assertEqual(d5["search"]["moves"], 5)  # Includes two self-play moves.
        self.assertEqual(study["longestGames"]["complete"][0]["blackTieBreakSeed"], 6000000)

    def test_censored_active_error_and_missing_are_not_draws(self):
        cfg = config(games_per_cell=5, pairs=[{"black": "D2", "white": "D5"}])
        path = self.write_study(cfg, [game(cfg, winner=None), game(cfg, trial=1, status="truncated", plies=10),
                                     game(cfg, trial=2, status="active", plies=4),
                                     game(cfg, trial=3, status="error", plies=2)])
        result = report.summarize_study(path)["pairs"][0]
        self.assertEqual(result["draws"], 1)
        self.assertEqual(result["unfinished"], 4)
        for key in ("truncated", "active", "error", "notStarted"):
            self.assertEqual(result[key], 1)
        self.assertIsNone(result["winRate"])
        self.assertIsNone(result["nominalWilson95WinRate"])
        self.assertEqual(result["winRateBounds"], [0, .8])
        self.assertEqual(result["scoreRateBounds"], [.1, .9])
        self.assertEqual(result["completedLengthPlies"]["mean"], 3)
        self.assertEqual(result["truncatedObservedPlies"]["max"], 10)
        self.assertEqual(result["activeObservedPlies"]["max"], 4)
        self.assertEqual(result["errorObservedPlies"]["max"], 2)

    def test_actual_effort_and_completed_horizon_are_separate(self):
        cfg = config(pairs=[{"black": "D5", "white": "D2"}])
        path = self.write_study(cfg, [game(cfg, black="D5", white="D2", plies=3)])
        result = report.summarize([path])
        search = result["studies"][0]["profiles"][1]["search"]
        self.assertEqual(search["successorEvaluations"]["mean"], 200)
        self.assertEqual(search["successorEvaluations"]["p95"], 300)
        self.assertEqual(search["elapsedMilliseconds"]["median"], 2)
        self.assertEqual(search["meanBudgetFraction"], .2)
        self.assertEqual(search["completedDepthHistogram"], {"5": 2})
        self.assertEqual(search["shareDepthAtLeast4"], 1)
        self.assertEqual(search["shareDepthAtLeast5"], 1)
        self.assertEqual(search["maxVisitedPly"]["max"], 1)
        self.assertIn("Completed horizon counts", report.render_markdown(result))

    def test_per_game_checkpoint_takes_precedence_over_stale_summary(self):
        cfg = config()
        current = game(cfg)
        stale = game(cfg, status="active", plies=0)
        path = self.write_study(cfg, [current], summary_games=[stale])
        self.assertEqual(report.summarize_study(path)["pairs"][0]["completed"], 1)

    def test_summary_only_pre_checkpoint_error(self):
        cfg = config()
        error = {**report.identity(cfg, "D2", "D5", 0), "status": "error", "error": "fixture failure"}
        path = self.write_study(cfg, summary_games=[error])
        result = report.summarize_study(path)["overallBlack"]
        self.assertEqual(result["error"], 1)
        self.assertEqual(result["notStarted"], 1)
        self.assertEqual(result["errorObservedPlies"]["n"], 0)

    def test_summary_completed_game_requires_checkpoint(self):
        cfg = config()
        path = self.write_study(cfg, summary_games=[game(cfg)])
        with self.assertRaisesRegex(report.ValidationError, "checkpoint is missing"):
            report.summarize_study(path)

    def test_loads_checkpoint_created_after_initial_directory_listing(self):
        cfg = config()
        item = game(cfg, winner="white")
        path = self.write_study(cfg, summary_games=[item]).resolve()
        checkpoint = path / "games" / "D2__D5__0.json"
        read_object = report.read_object

        def read_with_new_checkpoint(source):
            if source == path / "summary.json":
                checkpoint.write_text(json.dumps(item), encoding="utf-8")
            return read_object(source)

        with patch.object(report, "read_object", side_effect=read_with_new_checkpoint) as reads:
            result = report.summarize_study(path)
        self.assertEqual(result["pairs"][0]["losses"], 1)
        self.assertEqual(result["pairs"][0]["draws"], 0)
        self.assertEqual(sum(call.args[0] == checkpoint for call in reads.call_args_list), 1)

    def test_newly_discovered_checkpoint_still_requires_valid_identity(self):
        cfg = config()
        item = game(cfg)
        path = self.write_study(cfg, [item], summary_games=[item])
        item["blackTieBreakSeed"] += 1
        (path / "games" / "D2__D5__0.json").write_text(json.dumps(item), encoding="utf-8")
        with patch.object(Path, "glob", return_value=[]):
            with self.assertRaisesRegex(report.ValidationError, "game identity mismatch"):
                report.summarize_study(path)

    def test_rejects_missing_or_inconsistent_saved_outcomes(self):
        changes = {
            "missing winner": lambda item: item.pop("winner"),
            "missing reason": lambda item: item.pop("outcomeReason"),
            "wrong winner": lambda item: item.update(winner="white"),
            "wrong reason": lambda item: item.update(outcomeReason="mutualExtinction"),
            "missing state": lambda item: item.pop("state"),
            "missing state outcome": lambda item: item["state"].pop("outcome"),
            "wrong completion": lambda item: item["state"].update(outcome=None),
            "wrong status": lambda item: item["state"].update(status="active"),
            "wrong turn": lambda item: item["state"].update(toMove="white"),
            "wrong ply": lambda item: item["state"].update(ply=2),
            "wrong revision": lambda item: item["state"].update(revision=2),
            "wrong population": lambda item: item.update(blackPopulation=4),
            "wrong outcome population": lambda item: item["state"]["outcome"].update(blackPopulation=4),
            "wrong cells": lambda item: item["state"]["cells"].pop(),
            "invalid cell": lambda item: item["state"]["cells"].__setitem__(0, True),
            "win without winner": lambda item: item["state"]["outcome"].update(winner=None),
            "draw with winner": lambda item: item["state"]["outcome"].update(type="draw"),
        }
        for name, change in changes.items():
            with self.subTest(name=name):
                cfg = config()
                item = game(cfg)
                change(item)
                path = self.write_study(cfg, [item], name=name)
                with self.assertRaises(report.ValidationError):
                    report.summarize_study(path)

    def test_duplicate_paths_are_not_double_counted_and_copies_rejected(self):
        cfg = config()
        path = self.write_study(cfg, [game(cfg)])
        self.assertEqual(len(report.summarize([path, path])["studies"]), 1)
        copy_path = self.write_study(cfg, [game(cfg)], name="copy")
        with self.assertRaisesRegex(report.ValidationError, "same study config"):
            report.summarize([path, copy_path])

    def test_multiple_studies_are_separate(self):
        first = self.write_study(config())
        second = self.write_study(config("confirmation", 6100000), name="second")
        result = report.summarize([first, second])
        self.assertEqual([s["config"]["baseSeed"] for s in result["studies"]], [6000000, 6100000])
        self.assertNotIn("overallBlack", result)

    def test_rejects_identity_hash_budget_and_counter_corruption(self):
        changes = {
            "identity": lambda item: item.update(blackTieBreakSeed=5),
            "budget": lambda item: item["moves"][0].update(successorEvaluations=1001),
            "totals": lambda item: item["searchTotals"].update(cacheHits=0),
            "history": lambda item: item.update(plies=2),
            "depth": lambda item: item["moves"][0].update(completedDepth=3),
            "actual reach": lambda item: item["moves"][0].update(maxVisitedPly=3),
            "status": lambda item: item.update(status="truncated"),
            "turns": lambda item: item["moves"][0].update(player="white"),
        }
        for name, change in changes.items():
            with self.subTest(name=name):
                cfg = config()
                item = game(cfg)
                change(item)
                path = self.write_study(cfg, [item], name=name)
                with self.assertRaises(report.ValidationError):
                    report.summarize_study(path)
        cfg = config()
        cfg["transitionBudget"] = 999
        path = self.write_study(cfg, name="hash")
        with self.assertRaisesRegex(report.ValidationError, "hash mismatch"):
            report.summarize_study(path)

    def test_duplicate_summary_identity_is_rejected(self):
        cfg = config()
        item = game(cfg)
        path = self.write_study(cfg, [item], summary_games=[item, copy.deepcopy(item)])
        with self.assertRaisesRegex(report.ValidationError, "duplicate summary"):
            report.summarize_study(path)

    def test_percentiles_and_empty_records(self):
        self.assertEqual(report.distribution([10, 1, 2, 3])["median"], 2.5)
        self.assertEqual(report.distribution(list(range(1, 11)))["p90"], 9)
        self.assertIsNone(report.distribution([])["mean"])
        self.assertEqual(report.rate(report.outcomes([], "D5")), "—")

    def test_cli_writes_json_and_markdown_without_modifying_study(self):
        cfg = config()
        path = self.write_study(cfg, [game(cfg)])
        before = (path / "config.json").read_bytes()
        destination = self.root / "report.md"
        result = subprocess.run([sys.executable, str(Path(report.__file__)), str(path),
                                 f"--output={destination}"], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["studies"][0]["overallBlack"]["completed"], 1)
        markdown = destination.read_text(encoding="utf-8")
        self.assertIn("Black's perspective", markdown)
        self.assertIn("interim snapshot", markdown)
        self.assertIn("right-censored", markdown)
        self.assertIn("| ID |", markdown)
        self.assertEqual((path / "config.json").read_bytes(), before)

    def test_cli_error_is_concise(self):
        path = self.write_study(config())
        (path / "config.json").write_text("broken", encoding="utf-8")
        result = subprocess.run([sys.executable, str(Path(report.__file__)), str(path)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertTrue(result.stderr.startswith("error:"))
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()

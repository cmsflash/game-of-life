from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any, Protocol, cast

from .errors import ApiError
from .settings import Settings


class Engine(Protocol):
    def initial(self, rules: dict[str, Any]) -> dict[str, Any]: ...

    def apply_move(
        self,
        state: dict[str, Any],
        *,
        player: str,
        row: int,
        column: int,
        expected_revision: int,
    ) -> dict[str, Any]: ...

    def replay(self, rules: dict[str, Any], moves: list[dict[str, Any]]) -> dict[str, Any]: ...


class DartEngine:
    def __init__(self, settings: Settings, *, repository_root: Path | None = None) -> None:
        root = repository_root or Path(__file__).resolve().parents[3]
        if settings.engine_executable:
            self._command = [settings.engine_executable, "--once"]
        else:
            # Resolve eagerly when available, but let application construction
            # succeed in Python-only tooling. A missing runtime is surfaced as
            # a stable engineUnavailable response when a game operation runs.
            dart = shutil.which("dart") or "dart"
            entrypoint = root / "tools" / "game_cli" / "bin" / "game_cli.dart"
            self._command = [dart, "run", str(entrypoint), "--once"]
        self._cwd = root

    def initial(self, rules: dict[str, Any]) -> dict[str, Any]:
        state = self._invoke({"op": "initial", "rules": rules}).get("state")
        if not isinstance(state, dict):
            raise ApiError(
                "engineProtocolError",
                "The authoritative engine returned an invalid state.",
                status_code=503,
            )
        return cast(dict[str, Any], state)

    def apply_move(
        self,
        state: dict[str, Any],
        *,
        player: str,
        row: int,
        column: int,
        expected_revision: int,
    ) -> dict[str, Any]:
        return self._invoke(
            {
                "op": "applyMove",
                "state": state,
                "move": {
                    "player": player,
                    "row": row,
                    "column": column,
                    "expectedRevision": expected_revision,
                },
            }
        )

    def replay(self, rules: dict[str, Any], moves: list[dict[str, Any]]) -> dict[str, Any]:
        return self._invoke({"op": "replay", "rules": rules, "moves": moves})

    def _invoke(self, request: dict[str, Any]) -> dict[str, Any]:
        try:
            completed = subprocess.run(
                self._command,
                cwd=self._cwd,
                input=json.dumps(request, separators=(",", ":")),
                text=True,
                capture_output=True,
                timeout=15,
                check=False,
                env={**os.environ, "NO_COLOR": "1"},
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ApiError(
                "engineUnavailable",
                "The authoritative engine did not respond.",
                status_code=503,
            ) from error
        if completed.returncode != 0:
            raise ApiError(
                "engineUnavailable",
                "The authoritative engine failed.",
                status_code=503,
                details={"exitCode": completed.returncode},
            )
        try:
            response = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise ApiError(
                "engineProtocolError",
                "The authoritative engine returned invalid JSON.",
                status_code=503,
            ) from error
        if not response.get("ok"):
            engine_error = response.get("error", {})
            code = str(engine_error.get("code", "invalidMove"))
            status = (
                409 if code in {"staleRevision", "occupied", "wrongPlayer", "gameOver"} else 400
            )
            raise ApiError(
                code, str(engine_error.get("message", "The move is invalid.")), status_code=status
            )
        result = response.get("result")
        if not isinstance(result, dict):
            raise ApiError(
                "engineProtocolError",
                "The authoritative engine returned an invalid result.",
                status_code=503,
            )
        return result


def build_engine(settings: Settings) -> Engine:
    return DartEngine(settings)

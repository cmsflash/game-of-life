from __future__ import annotations

import hashlib
import json
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from .engine import Engine
from .errors import ApiError
from .models import (
    CreateMatchRequest,
    MatchDocument,
    MatchRulesRequest,
    MatchStatus,
    MoveEvent,
    MoveRequest,
    PlayerSummary,
    QuickMatchRequest,
    QuickMatchResponse,
    ReplayResponse,
    ResignRequest,
    StoredMatch,
    User,
)
from .repository import Repository


@dataclass(slots=True)
class MatchService:
    repository: Repository
    engine: Engine

    def create(self, user: User, request: CreateMatchRequest) -> MatchDocument:
        return self._create_waiting(user, request.rules)

    def _create_waiting(self, user: User, rules_request: MatchRulesRequest) -> MatchDocument:
        rules = rules_request.engine_rules()
        state = self.engine.initial(rules)
        match = StoredMatch(
            id=str(uuid4()),
            join_code=self._new_join_code(),
            rules=rules,
            state=state,
            creator_id=user.id,
            creator_name=user.display_name,
            status=MatchStatus.waiting,
        )
        self.repository.create_match(match)
        return self.document(match, user.id)

    def join(self, user: User, join_code: str) -> MatchDocument:
        match = self.repository.find_by_join_code(join_code)
        if match is None:
            raise ApiError("matchNotFound", "No match has that join code.", status_code=404)
        if match.creator_id == user.id:
            raise ApiError(
                "cannotJoinOwnMatch", "A second player must join this match.", status_code=409
            )
        if match.status != MatchStatus.waiting:
            raise ApiError("matchUnavailable", "The match is no longer waiting.", status_code=409)
        creator = PlayerSummary(id=match.creator_id, display_name=match.creator_name)
        joining = PlayerSummary(id=user.id, display_name=user.display_name)
        black, white = (creator, joining) if secrets.randbelow(2) == 0 else (joining, creator)
        updated = match.model_copy(
            update={
                "black_player": black,
                "white_player": white,
                "status": MatchStatus.active,
                "version": match.version + 1,
                "updated_at": datetime.now(UTC),
            }
        )
        self.repository.join_match(updated, user.id)
        return self.document(updated, user.id)

    def quick_match(self, user: User, request: QuickMatchRequest) -> QuickMatchResponse:
        existing = self.repository.matchmaking_status(user.id, request.ticket_id)
        if existing is not None:
            return self._quick_response(existing.ticket_id, existing.status, existing.match_id)
        active_request = self.repository.active_matchmaking(user.id)
        if active_request is not None:
            return self._quick_response(
                active_request.ticket_id,
                active_request.status,
                active_request.match_id,
            )
        lock_token = self.repository.acquire_matchmaking_lock(user.id)
        if lock_token is None:
            raise ApiError(
                "matchmakingBusy",
                "Another matchmaking request is still being processed.",
                status_code=409,
            )
        try:
            return self._quick_match_locked(user, request)
        finally:
            self.repository.release_matchmaking_lock(user.id, lock_token)

    def _quick_match_locked(self, user: User, request: QuickMatchRequest) -> QuickMatchResponse:
        existing = self.repository.matchmaking_status(user.id, request.ticket_id)
        if existing is not None:
            return self._quick_response(existing.ticket_id, existing.status, existing.match_id)
        active_request = self.repository.active_matchmaking(user.id)
        if active_request is not None:
            return self._quick_response(
                active_request.ticket_id,
                active_request.status,
                active_request.match_id,
            )
        rules = request.rules.engine_rules()
        rules_hash = _stable_hash(rules)
        opponent_entry = self.repository.pop_opponent(rules_hash, user.id)
        if opponent_entry is None:
            self.repository.enqueue(rules_hash, user, rules, request.ticket_id)
            return QuickMatchResponse(ticket_id=request.ticket_id, status="waiting")
        opponent, opponent_rules, opponent_ticket_id = opponent_entry
        try:
            state = self.engine.initial(opponent_rules)
            creator = PlayerSummary(id=opponent.id, display_name=opponent.display_name)
            joining = PlayerSummary(id=user.id, display_name=user.display_name)
            black, white = (creator, joining) if secrets.randbelow(2) == 0 else (joining, creator)
            active_match = StoredMatch(
                id=str(uuid4()),
                join_code=self._new_join_code(),
                rules=opponent_rules,
                state=state,
                creator_id=opponent.id,
                creator_name=opponent.display_name,
                black_player=black,
                white_player=white,
                status=MatchStatus.active,
                version=1,
            )
            self.repository.commit_quick_match(
                active_match,
                user.id,
                request.ticket_id,
                opponent_ticket_id,
            )
        except Exception:
            self.repository.release_matchmaking_claim(opponent.id, opponent_ticket_id)
            raise
        return QuickMatchResponse(
            ticket_id=request.ticket_id,
            status="matched",
            match_id=active_match.id,
        )

    def quick_status(self, user: User, ticket_id: str) -> QuickMatchResponse:
        record = self.repository.matchmaking_status(user.id, ticket_id)
        if record is None:
            raise ApiError(
                "matchmakingTicketNotFound",
                "That matchmaking ticket was not found or has expired.",
                status_code=404,
            )
        return self._quick_response(record.ticket_id, record.status, record.match_id)

    def cancel_quick_match(self, user: User, ticket_id: str) -> None:
        if self.repository.remove_from_queue(user.id, ticket_id):
            return
        record = self.repository.matchmaking_status(user.id, ticket_id)
        if record is not None and record.status == "matched" and record.match_id:
            raise ApiError(
                "matchAlreadyFound",
                "A match was found before cancellation completed.",
                status_code=409,
                details={"matchId": record.match_id},
            )

    @staticmethod
    def _quick_response(
        ticket_id: str,
        status: str,
        match_id: str | None,
    ) -> QuickMatchResponse:
        if status == "matched" and match_id is not None:
            return QuickMatchResponse(
                ticket_id=ticket_id,
                status="matched",
                match_id=match_id,
            )
        return QuickMatchResponse(ticket_id=ticket_id, status="waiting")

    def get(self, user: User, match_id: str) -> MatchDocument:
        match = self._authorized_match(user, match_id)
        return self.document(match, user.id)

    def list_matches(self, user: User) -> list[MatchDocument]:
        return [self.document(match, user.id) for match in self.repository.list_matches(user.id)]

    def cancel_waiting(self, user: User, match_id: str) -> None:
        match = self._authorized_match(user, match_id)
        if match.creator_id != user.id:
            raise ApiError(
                "matchForbidden",
                "Only the player who created this match may cancel it.",
                status_code=403,
            )
        if match.status != MatchStatus.waiting:
            raise ApiError(
                "matchUnavailable",
                "Only a waiting match may be cancelled.",
                status_code=409,
            )
        self.repository.cancel_waiting_match(match, user.id)

    def move(self, user: User, match_id: str, request: MoveRequest) -> MatchDocument:
        request_fingerprint = _stable_hash(
            {
                "operation": "move",
                "matchId": match_id,
                "row": request.row,
                "column": request.column,
                "expectedRevision": request.expected_revision,
            }
        )
        previous = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        if previous is not None:
            if previous.id != match_id:
                raise ApiError(
                    "idempotencyConflict",
                    "That idempotency key was used for another match.",
                    status_code=409,
                )
            return self.document(previous, user.id)
        match = self._authorized_match(user, match_id)
        if match.status != MatchStatus.active:
            raise ApiError("gameOver", "The match is not active.", status_code=409)
        color = match.color_for(user.id)
        if color is None:
            raise ApiError("notAPlayer", "Only a player may submit a move.", status_code=403)
        if request.expected_revision != match.revision:
            raise ApiError(
                "staleRevision",
                "The match has changed.",
                status_code=409,
                details={"currentRevision": match.revision},
            )
        turn = self.engine.apply_move(
            match.state,
            player=color,
            row=request.row,
            column=request.column,
            expected_revision=request.expected_revision,
        )
        state = turn["state"]
        outcome = state.get("outcome")
        now = datetime.now(UTC)
        updated = match.model_copy(
            update={
                "state": state,
                "status": MatchStatus.completed if outcome else MatchStatus.active,
                "result": outcome,
                "version": match.version + 1,
                "updated_at": now,
            }
        )
        event = MoveEvent(
            revision=int(state["revision"]),
            actor_id=user.id,
            player=color,
            row=request.row,
            column=request.column,
            delta=turn["delta"],
            state_hash=str(state["stateHash"]),
            created_at=now,
        )
        self.repository.commit_move(
            match=updated,
            expected_version=match.version,
            event=event,
            user_id=user.id,
            idempotency_key=request.idempotency_key,
            request_fingerprint=request_fingerprint,
        )
        committed = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        if committed is not None and committed.id != match_id:
            raise ApiError(
                "idempotencyConflict",
                "That idempotency key was used for another match.",
                status_code=409,
            )
        return self.document(committed or updated, user.id)

    def resign(self, user: User, match_id: str, request: ResignRequest) -> MatchDocument:
        request_fingerprint = _stable_hash(
            {
                "operation": "resign",
                "matchId": match_id,
                "expectedRevision": request.expected_revision,
            }
        )
        previous = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        if previous is not None:
            if previous.id != match_id:
                raise ApiError(
                    "idempotencyConflict",
                    "That idempotency key was used for another match.",
                    status_code=409,
                )
            return self.document(previous, user.id)
        match = self._authorized_match(user, match_id)
        if match.status != MatchStatus.active:
            raise ApiError("gameOver", "The match is not active.", status_code=409)
        color = match.color_for(user.id)
        if color is None:
            raise ApiError("notAPlayer", "Only a player may resign.", status_code=403)
        if request.expected_revision != match.revision:
            raise ApiError(
                "staleRevision",
                "The match has changed.",
                status_code=409,
                details={"currentRevision": match.revision},
            )
        winner = "white" if color == "black" else "black"
        updated = match.model_copy(
            update={
                "status": MatchStatus.completed,
                "result": {"type": "win", "winner": winner, "reason": "resignation"},
                "version": match.version + 1,
                "updated_at": datetime.now(UTC),
            }
        )
        self.repository.commit_resignation(
            match=updated,
            expected_version=match.version,
            user_id=user.id,
            idempotency_key=request.idempotency_key,
            request_fingerprint=request_fingerprint,
        )
        committed = self.repository.idempotent_result(
            user.id, request.idempotency_key, request_fingerprint
        )
        return self.document(committed or updated, user.id)

    def history(self, user: User, match_id: str) -> list[MoveEvent]:
        self._authorized_match(user, match_id)
        return self.repository.list_moves(match_id)

    def replay(self, user: User, match_id: str) -> ReplayResponse:
        match = self._authorized_match(user, match_id)
        moves = self.repository.list_moves(match_id)
        replay_moves = [
            {"player": move.player, "row": move.row, "column": move.column} for move in moves
        ]
        replay = self.engine.replay(match.rules, replay_moves)
        return ReplayResponse(
            match_id=match.id,
            rules=match.rules,
            initial_state=self.engine.initial(match.rules),
            moves=moves,
            final_state=replay["state"],
            result=match.result,
        )

    def document(self, match: StoredMatch, user_id: str) -> MatchDocument:
        return MatchDocument(
            id=match.id,
            join_code=match.join_code,
            rules=match.rules,
            state=match.state,
            black_player=match.black_player,
            white_player=match.white_player,
            your_color=match.color_for(user_id),
            status=match.status,
            version=match.version,
            result=match.result,
            created_at=match.created_at,
            updated_at=match.updated_at,
        )

    def _authorized_match(self, user: User, match_id: str) -> StoredMatch:
        match = self.repository.get_match(match_id)
        if match is None:
            raise ApiError("matchNotFound", "The match was not found.", status_code=404)
        participant_ids = {
            match.creator_id,
            match.black_player.id if match.black_player else None,
            match.white_player.id if match.white_player else None,
        }
        if user.id not in participant_ids:
            raise ApiError(
                "matchForbidden", "You do not have access to this match.", status_code=403
            )
        return match

    def _new_join_code(self) -> str:
        alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        for _ in range(20):
            code = "".join(secrets.choice(alphabet) for _ in range(6))
            if self.repository.find_by_join_code(code) is None:
                return code
        raise ApiError("capacityError", "A join code could not be allocated.", status_code=503)


def _stable_hash(value: dict[str, Any]) -> str:
    canonical = json.dumps(value, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(canonical.encode()).hexdigest()

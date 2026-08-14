from __future__ import annotations

import json
import secrets
import threading
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal, Protocol
from uuid import uuid4

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from .errors import ApiError
from .models import (
    MatchStatus,
    MoveEvent,
    PlayerSummary,
    StoredExchange,
    StoredMatch,
    StoredOAuthTransaction,
    StoredPushSubscription,
)
from .settings import Settings

_MATCHMAKING_WAIT_TTL = timedelta(minutes=10)
_MATCHMAKING_RESULT_TTL = timedelta(hours=1)


@dataclass(frozen=True, slots=True)
class MatchmakingRecord:
    ticket_id: str
    status: Literal["waiting", "claimed", "matched"]
    rules_hash: str | None
    queue_sk: str | None
    match_id: str | None
    expires_at: datetime


class Repository(Protocol):
    def create_match(self, match: StoredMatch) -> None: ...

    def get_match(self, match_id: str) -> StoredMatch | None: ...

    def find_by_join_code(self, join_code: str) -> StoredMatch | None: ...

    def list_matches(self, user_id: str) -> list[StoredMatch]: ...

    def join_match(self, match: StoredMatch, joining_user_id: str) -> None: ...

    def cancel_waiting_match(self, match: StoredMatch, user_id: str) -> None: ...

    def idempotent_result(
        self, user_id: str, key: str, request_fingerprint: str
    ) -> StoredMatch | None: ...

    def commit_move(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        event: MoveEvent,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
    ) -> None: ...

    def commit_resignation(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
    ) -> None: ...

    def list_moves(self, match_id: str) -> list[MoveEvent]: ...

    def enqueue(
        self,
        rules_hash: str,
        user_id: str,
        rules: dict[str, Any],
        ticket_id: str,
    ) -> None: ...

    def pop_opponent(
        self, rules_hash: str, user_id: str
    ) -> tuple[str, dict[str, Any], str] | None: ...

    def active_matchmaking(self, user_id: str) -> MatchmakingRecord | None: ...

    def matchmaking_status(self, user_id: str, ticket_id: str) -> MatchmakingRecord | None: ...

    def commit_quick_match(
        self,
        match: StoredMatch,
        joining_user_id: str,
        requester_ticket_id: str,
        opponent_ticket_id: str,
    ) -> None: ...

    def release_matchmaking_claim(self, user_id: str, ticket_id: str) -> None: ...

    def remove_from_queue(self, user_id: str, ticket_id: str) -> bool: ...

    def acquire_matchmaking_lock(self, user_id: str) -> str | None: ...

    def release_matchmaking_lock(self, user_id: str, token: str) -> None: ...

    def put_exchange(self, exchange: StoredExchange) -> None: ...

    def consume_exchange(self, code: str) -> StoredExchange | None: ...

    def put_oauth_transaction(self, transaction: StoredOAuthTransaction) -> None: ...

    def consume_oauth_transaction(self, transaction_id: str) -> StoredOAuthTransaction | None: ...

    def upsert_push_subscription(
        self, subscription: StoredPushSubscription
    ) -> StoredPushSubscription: ...

    def list_push_subscriptions(self, user_id: str) -> list[StoredPushSubscription]: ...

    def get_push_subscription(
        self, user_id: str, installation_id: str
    ) -> StoredPushSubscription | None: ...

    def delete_push_subscription(self, user_id: str, installation_id: str) -> None: ...

    def delete_push_subscription_if_unchanged(
        self, subscription: StoredPushSubscription
    ) -> bool: ...

    def claim_notification_delivery(self, delivery_id: str) -> str | None: ...

    def complete_notification_delivery(self, delivery_id: str, claim_token: str) -> None: ...

    def release_notification_delivery(self, delivery_id: str, claim_token: str) -> None: ...

    def delete_user_data(self, user_id: str) -> None: ...


class InMemoryRepository:
    def __init__(self) -> None:
        self._matches: dict[str, StoredMatch] = {}
        self._join_codes: dict[str, str] = {}
        self._memberships: dict[str, set[str]] = {}
        self._moves: dict[str, list[MoveEvent]] = {}
        self._idempotency: dict[tuple[str, str], tuple[str, StoredMatch]] = {}
        self._queues: dict[str, list[tuple[str, dict[str, Any], str, datetime]]] = {}
        self._active_ticket_by_user: dict[str, str] = {}
        self._matchmaking_records: dict[tuple[str, str], MatchmakingRecord] = {}
        self._exchanges: dict[str, StoredExchange] = {}
        self._oauth_transactions: dict[str, StoredOAuthTransaction] = {}
        self._push_subscriptions: dict[tuple[str, str], StoredPushSubscription] = {}
        self._installation_owners: dict[str, str] = {}
        self._notification_deliveries: dict[str, tuple[str, datetime, str]] = {}
        self._deleted_users: set[str] = set()
        self._matchmaking_locks: dict[str, str] = {}
        self._lock = threading.RLock()

    def create_match(self, match: StoredMatch) -> None:
        with self._lock:
            if match.id in self._matches or match.join_code in self._join_codes:
                raise ApiError("conflict", "The match already exists.", status_code=409)
            self._matches[match.id] = match.model_copy(deep=True)
            self._join_codes[match.join_code] = match.id
            self._memberships.setdefault(match.creator_id, set()).add(match.id)
            self._moves[match.id] = []

    def get_match(self, match_id: str) -> StoredMatch | None:
        with self._lock:
            value = self._matches.get(match_id)
            return value.model_copy(deep=True) if value else None

    def find_by_join_code(self, join_code: str) -> StoredMatch | None:
        match_id = self._join_codes.get(join_code)
        return self.get_match(match_id) if match_id else None

    def list_matches(self, user_id: str) -> list[StoredMatch]:
        with self._lock:
            matches = [
                self._matches[mid].model_copy(deep=True)
                for mid in self._memberships.get(user_id, set())
            ]
        return sorted(matches, key=lambda item: item.updated_at, reverse=True)

    def join_match(self, match: StoredMatch, joining_user_id: str) -> None:
        with self._lock:
            current = self._matches.get(match.id)
            if current is None:
                raise ApiError("matchNotFound", "The match was not found.", status_code=404)
            if current.status.value != "waiting":
                raise ApiError(
                    "matchUnavailable", "The match is no longer waiting.", status_code=409
                )
            if current.version != match.version - 1:
                raise ApiError(
                    "matchUnavailable", "The match is no longer waiting.", status_code=409
                )
            self._matches[match.id] = match.model_copy(deep=True)
            self._memberships.setdefault(joining_user_id, set()).add(match.id)

    def cancel_waiting_match(self, match: StoredMatch, user_id: str) -> None:
        with self._lock:
            current = self._matches.get(match.id)
            if (
                current is None
                or current.creator_id != user_id
                or current.status.value != "waiting"
                or current.version != match.version
            ):
                raise ApiError(
                    "matchUnavailable",
                    "The waiting match can no longer be cancelled.",
                    status_code=409,
                )
            self._matches.pop(match.id, None)
            self._join_codes.pop(match.join_code, None)
            self._memberships.get(user_id, set()).discard(match.id)
            self._moves.pop(match.id, None)

    def idempotent_result(
        self, user_id: str, key: str, request_fingerprint: str
    ) -> StoredMatch | None:
        with self._lock:
            entry = self._idempotency.get((user_id, key))
            if entry is None:
                return None
            fingerprint, result = entry
            if fingerprint != request_fingerprint:
                raise ApiError(
                    "idempotencyConflict",
                    "That idempotency key was used for a different request.",
                    status_code=409,
                )
            return result.model_copy(deep=True)

    def commit_move(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        event: MoveEvent,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
    ) -> None:
        with self._lock:
            existing = self._idempotency.get((user_id, idempotency_key))
            if existing is not None:
                if existing[0] != request_fingerprint:
                    raise ApiError(
                        "idempotencyConflict",
                        "That idempotency key was used for a different request.",
                        status_code=409,
                    )
                return
            current = self._matches.get(match.id)
            if current is None:
                raise ApiError("matchNotFound", "The match was not found.", status_code=404)
            if current.version != expected_version:
                raise ApiError(
                    "staleRevision",
                    "The match changed before this move was committed.",
                    status_code=409,
                    details={"currentRevision": current.revision},
                )
            self._matches[match.id] = match.model_copy(deep=True)
            self._moves.setdefault(match.id, []).append(event.model_copy(deep=True))
            self._idempotency[(user_id, idempotency_key)] = (
                request_fingerprint,
                match.model_copy(deep=True),
            )

    def commit_resignation(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
    ) -> None:
        with self._lock:
            existing = self._idempotency.get((user_id, idempotency_key))
            if existing is not None:
                if existing[0] != request_fingerprint:
                    raise ApiError(
                        "idempotencyConflict",
                        "That idempotency key was used for a different request.",
                        status_code=409,
                    )
                return
            current = self._matches.get(match.id)
            if current is None:
                raise ApiError("matchNotFound", "The match was not found.", status_code=404)
            if current.version != expected_version:
                raise ApiError("staleRevision", "The match changed.", status_code=409)
            self._matches[match.id] = match.model_copy(deep=True)
            self._idempotency[(user_id, idempotency_key)] = (
                request_fingerprint,
                match.model_copy(deep=True),
            )

    def list_moves(self, match_id: str) -> list[MoveEvent]:
        with self._lock:
            return [move.model_copy(deep=True) for move in self._moves.get(match_id, [])]

    def enqueue(
        self,
        rules_hash: str,
        user_id: str,
        rules: dict[str, Any],
        ticket_id: str,
    ) -> None:
        with self._lock:
            active = self.active_matchmaking(user_id)
            if active is not None:
                if active.ticket_id == ticket_id:
                    return
                raise ApiError(
                    "matchmakingConflict",
                    "The player already has an active matchmaking request.",
                    status_code=409,
                    details={"ticketId": active.ticket_id},
                )
            expires_at = datetime.now(UTC) + _MATCHMAKING_WAIT_TTL
            self._queues.setdefault(rules_hash, []).append((user_id, rules, ticket_id, expires_at))
            self._active_ticket_by_user[user_id] = ticket_id
            self._matchmaking_records[(user_id, ticket_id)] = MatchmakingRecord(
                ticket_id=ticket_id,
                status="waiting",
                rules_hash=rules_hash,
                queue_sk=ticket_id,
                match_id=None,
                expires_at=expires_at,
            )

    def pop_opponent(self, rules_hash: str, user_id: str) -> tuple[str, dict[str, Any], str] | None:
        with self._lock:
            queue = self._queues.setdefault(rules_hash, [])
            now = datetime.now(UTC)
            queue[:] = [
                candidate for candidate in queue if self._keep_live_candidate(candidate, now)
            ]
            for candidate in queue:
                opponent_id, opponent_rules, ticket_id, _ = candidate
                record = self._matchmaking_records.get((opponent_id, ticket_id))
                if opponent_id != user_id and record is not None and record.status == "waiting":
                    self._matchmaking_records[(opponent_id, ticket_id)] = MatchmakingRecord(
                        ticket_id=ticket_id,
                        status="claimed",
                        rules_hash=rules_hash,
                        queue_sk=record.queue_sk,
                        match_id=None,
                        expires_at=now + _MATCHMAKING_WAIT_TTL,
                    )
                    return opponent_id, opponent_rules, ticket_id
            return None

    def _keep_live_candidate(
        self,
        candidate: tuple[str, dict[str, Any], str, datetime],
        now: datetime,
    ) -> bool:
        user_id, _, ticket_id, expires_at = candidate
        if expires_at > now:
            return True
        if self._active_ticket_by_user.get(user_id) == ticket_id:
            self._active_ticket_by_user.pop(user_id, None)
        self._matchmaking_records.pop((user_id, ticket_id), None)
        return False

    def active_matchmaking(self, user_id: str) -> MatchmakingRecord | None:
        with self._lock:
            ticket_id = self._active_ticket_by_user.get(user_id)
            if ticket_id is None:
                return None
            return self.matchmaking_status(user_id, ticket_id)

    def matchmaking_status(self, user_id: str, ticket_id: str) -> MatchmakingRecord | None:
        with self._lock:
            record = self._matchmaking_records.get((user_id, ticket_id))
            if record is None:
                return None
            if record.expires_at > datetime.now(UTC):
                return record
            self.remove_from_queue(user_id, ticket_id)
            self._matchmaking_records.pop((user_id, ticket_id), None)
            return None

    def commit_quick_match(
        self,
        match: StoredMatch,
        joining_user_id: str,
        requester_ticket_id: str,
        opponent_ticket_id: str,
    ) -> None:
        with self._lock:
            opponent_id = match.creator_id
            claimed = self._matchmaking_records.get((opponent_id, opponent_ticket_id))
            if claimed is None or claimed.status != "claimed":
                raise ApiError(
                    "matchmakingConflict",
                    "The opponent is no longer reserved for this match.",
                    status_code=409,
                )
            if match.id in self._matches or match.join_code in self._join_codes:
                raise ApiError("conflict", "The match already exists.", status_code=409)

            self._matches[match.id] = match.model_copy(deep=True)
            self._join_codes[match.join_code] = match.id
            self._memberships.setdefault(opponent_id, set()).add(match.id)
            self._memberships.setdefault(joining_user_id, set()).add(match.id)
            self._moves[match.id] = []
            if claimed.rules_hash is not None:
                self._queues[claimed.rules_hash] = [
                    entry
                    for entry in self._queues.get(claimed.rules_hash, [])
                    if not (entry[0] == opponent_id and entry[2] == opponent_ticket_id)
                ]
            if self._active_ticket_by_user.get(opponent_id) == opponent_ticket_id:
                self._active_ticket_by_user.pop(opponent_id, None)
            expires_at = datetime.now(UTC) + _MATCHMAKING_RESULT_TTL
            self._matchmaking_records[(opponent_id, opponent_ticket_id)] = MatchmakingRecord(
                ticket_id=opponent_ticket_id,
                status="matched",
                rules_hash=claimed.rules_hash,
                queue_sk=claimed.queue_sk,
                match_id=match.id,
                expires_at=expires_at,
            )
            self._matchmaking_records[(joining_user_id, requester_ticket_id)] = MatchmakingRecord(
                ticket_id=requester_ticket_id,
                status="matched",
                rules_hash=claimed.rules_hash,
                queue_sk=None,
                match_id=match.id,
                expires_at=expires_at,
            )

    def release_matchmaking_claim(self, user_id: str, ticket_id: str) -> None:
        with self._lock:
            current = self._matchmaking_records.get((user_id, ticket_id))
            if current is None or current.status != "claimed":
                return
            expires_at = datetime.now(UTC) + _MATCHMAKING_WAIT_TTL
            self._matchmaking_records[(user_id, ticket_id)] = MatchmakingRecord(
                ticket_id=ticket_id,
                status="waiting",
                rules_hash=current.rules_hash,
                queue_sk=current.queue_sk,
                match_id=None,
                expires_at=expires_at,
            )
            if current.rules_hash is not None:
                queue = self._queues.get(current.rules_hash, [])
                for index, entry in enumerate(queue):
                    if entry[0] == user_id and entry[2] == ticket_id:
                        queue[index] = (entry[0], entry[1], entry[2], expires_at)
                        break

    def remove_from_queue(self, user_id: str, ticket_id: str) -> bool:
        with self._lock:
            if self._active_ticket_by_user.get(user_id) != ticket_id:
                return False
            record = self._matchmaking_records.get((user_id, ticket_id))
            if record is None or record.status not in {"waiting", "claimed"}:
                return False
            self._active_ticket_by_user.pop(user_id, None)
            if record is not None and record.rules_hash is not None:
                rules_hash = record.rules_hash
                self._queues[rules_hash] = [
                    entry
                    for entry in self._queues.get(rules_hash, [])
                    if not (entry[0] == user_id and entry[2] == ticket_id)
                ]
            self._matchmaking_records.pop((user_id, ticket_id), None)
            return True

    def acquire_matchmaking_lock(self, user_id: str) -> str | None:
        with self._lock:
            if user_id in self._matchmaking_locks:
                return None
            token = secrets.token_urlsafe(18)
            self._matchmaking_locks[user_id] = token
            return token

    def release_matchmaking_lock(self, user_id: str, token: str) -> None:
        with self._lock:
            if self._matchmaking_locks.get(user_id) == token:
                self._matchmaking_locks.pop(user_id, None)

    def put_exchange(self, exchange: StoredExchange) -> None:
        with self._lock:
            self._exchanges[exchange.code] = exchange

    def consume_exchange(self, code: str) -> StoredExchange | None:
        with self._lock:
            exchange = self._exchanges.pop(code, None)
            if exchange is None or exchange.expires_at <= datetime.now(UTC):
                return None
            return exchange

    def put_oauth_transaction(self, transaction: StoredOAuthTransaction) -> None:
        with self._lock:
            self._oauth_transactions[transaction.id] = transaction.model_copy(deep=True)

    def consume_oauth_transaction(self, transaction_id: str) -> StoredOAuthTransaction | None:
        with self._lock:
            transaction = self._oauth_transactions.pop(transaction_id, None)
            if transaction is None or transaction.expires_at <= datetime.now(UTC):
                return None
            return transaction

    def upsert_push_subscription(
        self, subscription: StoredPushSubscription
    ) -> StoredPushSubscription:
        with self._lock:
            if subscription.user_id in self._deleted_users:
                raise ApiError(
                    "pushSubscriptionConflict",
                    "That account can no longer register notifications.",
                    status_code=409,
                )
            previous_owner = self._installation_owners.get(subscription.installation_id)
            if previous_owner is not None and previous_owner != subscription.user_id:
                self._push_subscriptions.pop(
                    (previous_owner, subscription.installation_id),
                    None,
                )
            existing = self._push_subscriptions.get(
                (subscription.user_id, subscription.installation_id)
            )
            stored = subscription.model_copy(
                update={"created_at": existing.created_at if existing else subscription.created_at}
            )
            self._push_subscriptions[(subscription.user_id, subscription.installation_id)] = (
                stored.model_copy(deep=True)
            )
            self._installation_owners[subscription.installation_id] = subscription.user_id
            return stored.model_copy(deep=True)

    def list_push_subscriptions(self, user_id: str) -> list[StoredPushSubscription]:
        with self._lock:
            subscriptions = [
                subscription.model_copy(deep=True)
                for (owner_id, _), subscription in self._push_subscriptions.items()
                if owner_id == user_id
            ]
        return sorted(subscriptions, key=lambda value: value.created_at)

    def get_push_subscription(
        self, user_id: str, installation_id: str
    ) -> StoredPushSubscription | None:
        with self._lock:
            subscription = self._push_subscriptions.get((user_id, installation_id))
            return subscription.model_copy(deep=True) if subscription is not None else None

    def delete_push_subscription(self, user_id: str, installation_id: str) -> None:
        with self._lock:
            self._push_subscriptions.pop((user_id, installation_id), None)
            if self._installation_owners.get(installation_id) == user_id:
                self._installation_owners.pop(installation_id, None)

    def delete_push_subscription_if_unchanged(self, subscription: StoredPushSubscription) -> bool:
        with self._lock:
            key = (subscription.user_id, subscription.installation_id)
            if self._push_subscriptions.get(key) != subscription:
                return False
            self._push_subscriptions.pop(key, None)
            if self._installation_owners.get(subscription.installation_id) == subscription.user_id:
                self._installation_owners.pop(subscription.installation_id, None)
            return True

    def claim_notification_delivery(self, delivery_id: str) -> str | None:
        with self._lock:
            now = datetime.now(UTC)
            existing = self._notification_deliveries.get(delivery_id)
            if existing is not None:
                state, lease_expires_at, _ = existing
                if state == "delivered" or lease_expires_at > now:
                    return None
            claim_token = secrets.token_urlsafe(18)
            self._notification_deliveries[delivery_id] = (
                "sending",
                now + timedelta(minutes=5),
                claim_token,
            )
            return claim_token

    def complete_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        with self._lock:
            current = self._notification_deliveries.get(delivery_id)
            if current is None or current[2] != claim_token:
                return
            self._notification_deliveries[delivery_id] = (
                "delivered",
                datetime.now(UTC) + timedelta(days=7),
                claim_token,
            )

    def release_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        with self._lock:
            current = self._notification_deliveries.get(delivery_id)
            if current is not None and current[0] == "sending" and current[2] == claim_token:
                self._notification_deliveries.pop(delivery_id, None)

    def delete_user_data(self, user_id: str) -> None:
        with self._lock:
            matches = [
                self._matches[match_id]
                for match_id in self._memberships.get(user_id, set())
                if match_id in self._matches
            ]
            if any(match.status != MatchStatus.completed for match in matches):
                raise ApiError(
                    "accountDeletionConflict",
                    "All active matches must end before account data can be deleted.",
                    status_code=409,
                )

            self._deleted_users.add(user_id)

            for match in matches:
                anonymous_id = f"deleted-{uuid4()}"
                anonymized = _anonymize_match(match, user_id, anonymous_id)
                self._matches[match.id] = anonymized
                self._moves[match.id] = [
                    _anonymize_move(move, user_id, anonymous_id)
                    for move in self._moves.get(match.id, [])
                ]

            self._memberships.pop(user_id, None)
            self._idempotency = {
                key: value for key, value in self._idempotency.items() if key[0] != user_id
            }
            for rules_hash, queue in self._queues.items():
                self._queues[rules_hash] = [entry for entry in queue if entry[0] != user_id]
            self._active_ticket_by_user.pop(user_id, None)
            self._matchmaking_records = {
                key: value for key, value in self._matchmaking_records.items() if key[0] != user_id
            }
            self._matchmaking_locks.pop(user_id, None)
            installation_ids = [
                installation_id
                for owner_id, installation_id in self._push_subscriptions
                if owner_id == user_id
            ]
            for installation_id in installation_ids:
                self._push_subscriptions.pop((user_id, installation_id), None)
                if self._installation_owners.get(installation_id) == user_id:
                    self._installation_owners.pop(installation_id, None)


class DynamoRepository:
    """Single-table DynamoDB implementation used by the Lambda deployment."""

    def __init__(self, settings: Settings) -> None:
        self._table = boto3.resource("dynamodb", region_name=settings.aws_region).Table(
            settings.table_name
        )
        # Transaction payloads below use explicit DynamoDB AttributeValue maps.
        # A resource-backed Table client installs an additional serializer and
        # would encode those maps a second time (for example, S keys as M).
        self._client = boto3.client("dynamodb", region_name=settings.aws_region)
        self._table_name = settings.table_name

    @staticmethod
    def _match_item(match: StoredMatch) -> dict[str, Any]:
        return {
            "PK": f"MATCH#{match.id}",
            "SK": "STATE",
            "entity": "match",
            "revision": match.revision,
            "version": match.version,
            "status": match.status.value,
            "creatorId": match.creator_id,
            "document": match.model_dump_json(by_alias=True),
        }

    @staticmethod
    def _parse_match(item: dict[str, Any] | None) -> StoredMatch | None:
        if not item:
            return None
        return StoredMatch.model_validate_json(item["document"])

    def create_match(self, match: StoredMatch) -> None:
        membership = {
            "PK": f"USER#{match.creator_id}",
            "SK": f"MATCH#{match.id}",
            "entity": "membership",
            "matchId": match.id,
        }
        join = {
            "PK": f"JOIN#{match.join_code}",
            "SK": "JOIN",
            "entity": "joinCode",
            "matchId": match.id,
        }
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {"Put": {"TableName": self._table_name, "Item": _serialize(membership)}},
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(join),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "conflict", "The match could not be created.", status_code=409
                ) from error
            raise

    def get_match(self, match_id: str) -> StoredMatch | None:
        response = self._table.get_item(
            Key={"PK": f"MATCH#{match_id}", "SK": "STATE"}, ConsistentRead=True
        )
        return self._parse_match(response.get("Item"))

    def find_by_join_code(self, join_code: str) -> StoredMatch | None:
        response = self._table.get_item(
            Key={"PK": f"JOIN#{join_code}", "SK": "JOIN"}, ConsistentRead=True
        )
        item = response.get("Item")
        return self.get_match(item["matchId"]) if item else None

    def list_matches(self, user_id: str) -> list[StoredMatch]:
        items: list[dict[str, Any]] = []
        query: dict[str, Any] = {
            "KeyConditionExpression": Key("PK").eq(f"USER#{user_id}")
            & Key("SK").begins_with("MATCH#")
        }
        while True:
            response = self._table.query(**query)
            items.extend(response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                break
            query["ExclusiveStartKey"] = last_key
        matches = [self.get_match(item["matchId"]) for item in items]
        return sorted(
            (match for match in matches if match), key=lambda item: item.updated_at, reverse=True
        )

    def join_match(self, match: StoredMatch, joining_user_id: str) -> None:
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": ("#status = :waiting AND #version = :version"),
                            "ExpressionAttributeNames": {
                                "#status": "status",
                                "#version": "version",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {":waiting": "waiting", ":version": match.version - 1}
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{joining_user_id}",
                                    "SK": f"MATCH#{match.id}",
                                    "entity": "membership",
                                    "matchId": match.id,
                                }
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "matchUnavailable", "The match is no longer waiting.", status_code=409
                ) from error
            raise

    def cancel_waiting_match(self, match: StoredMatch, user_id: str) -> None:
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"MATCH#{match.id}", "SK": "STATE"}),
                            "ConditionExpression": (
                                "#status = :waiting AND #version = :version "
                                "AND creatorId = :creator"
                            ),
                            "ExpressionAttributeNames": {
                                "#status": "status",
                                "#version": "version",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":version": match.version,
                                    ":creator": user_id,
                                }
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"JOIN#{match.join_code}", "SK": "JOIN"}),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"USER#{user_id}", "SK": f"MATCH#{match.id}"}),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "matchUnavailable",
                    "The waiting match can no longer be cancelled.",
                    status_code=409,
                ) from error
            raise

    def idempotent_result(
        self, user_id: str, key: str, request_fingerprint: str
    ) -> StoredMatch | None:
        response = self._table.get_item(
            Key={"PK": f"IDEMP#{user_id}", "SK": key}, ConsistentRead=True
        )
        item = response.get("Item")
        if not item:
            return None
        if item.get("requestFingerprint") != request_fingerprint:
            raise ApiError(
                "idempotencyConflict",
                "That idempotency key was used for a different request.",
                status_code=409,
            )
        return StoredMatch.model_validate_json(item["document"])

    def commit_move(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        event: MoveEvent,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
    ) -> None:
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": ("#version = :version AND #status = :active"),
                            "ExpressionAttributeNames": {
                                "#version": "version",
                                "#status": "status",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {":version": expected_version, ":active": "active"}
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"MATCH#{match.id}",
                                    "SK": f"MOVE#{event.revision:08d}",
                                    "entity": "move",
                                    "document": event.model_dump_json(by_alias=True),
                                }
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"IDEMP#{user_id}",
                                    "SK": idempotency_key,
                                    "entity": "idempotency",
                                    "document": match.model_dump_json(by_alias=True),
                                    "requestFingerprint": request_fingerprint,
                                    "expiresAt": int(datetime.now(UTC).timestamp()) + 86400,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.idempotent_result(user_id, idempotency_key, request_fingerprint)
                if existing is not None:
                    return
                current = self.get_match(match.id)
                raise ApiError(
                    "staleRevision",
                    "The match changed before this move was committed.",
                    status_code=409,
                    details={"currentRevision": current.revision if current else None},
                ) from error
            raise

    def commit_resignation(
        self,
        *,
        match: StoredMatch,
        expected_version: int,
        user_id: str,
        idempotency_key: str,
        request_fingerprint: str,
    ) -> None:
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": ("#version = :version AND #status = :active"),
                            "ExpressionAttributeNames": {
                                "#version": "version",
                                "#status": "status",
                            },
                            "ExpressionAttributeValues": _serialize_values(
                                {":version": expected_version, ":active": "active"}
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"IDEMP#{user_id}",
                                    "SK": idempotency_key,
                                    "entity": "idempotency",
                                    "document": match.model_dump_json(by_alias=True),
                                    "requestFingerprint": request_fingerprint,
                                    "expiresAt": int(datetime.now(UTC).timestamp()) + 86400,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.idempotent_result(user_id, idempotency_key, request_fingerprint)
                if existing is not None:
                    return
                raise ApiError("staleRevision", "The match changed.", status_code=409) from error
            raise

    def list_moves(self, match_id: str) -> list[MoveEvent]:
        items: list[dict[str, Any]] = []
        query: dict[str, Any] = {
            "KeyConditionExpression": Key("PK").eq(f"MATCH#{match_id}")
            & Key("SK").begins_with("MOVE#")
        }
        while True:
            response = self._table.query(**query)
            items.extend(response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                break
            query["ExclusiveStartKey"] = last_key
        return [MoveEvent.model_validate_json(item["document"]) for item in items]

    def enqueue(
        self,
        rules_hash: str,
        user_id: str,
        rules: dict[str, Any],
        ticket_id: str,
    ) -> None:
        now = datetime.now(UTC)
        queue_sk = f"{now.isoformat()}#{user_id}"
        expires_at = int((now + _MATCHMAKING_WAIT_TTL).timestamp())
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"QUEUE#{rules_hash}",
                                    "SK": queue_sk,
                                    "entity": "queue",
                                    "userId": user_id,
                                    "ticketId": ticket_id,
                                    "status": "waiting",
                                    "rules": json.dumps(
                                        rules, separators=(",", ":"), sort_keys=True
                                    ),
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{user_id}",
                                    "SK": "QUEUE",
                                    "entity": "queuePointer",
                                    "ticketId": ticket_id,
                                    "status": "waiting",
                                    "rulesHash": rules_hash,
                                    "queueSk": queue_sk,
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{user_id}",
                                    "SK": f"TICKET#{ticket_id}",
                                    "entity": "matchmakingTicket",
                                    "ticketId": ticket_id,
                                    "status": "waiting",
                                    "rulesHash": rules_hash,
                                    "queueSk": queue_sk,
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.matchmaking_status(user_id, ticket_id)
                if existing is not None:
                    return
                raise ApiError(
                    "matchmakingConflict",
                    "The matchmaking request conflicted with another request.",
                    status_code=409,
                ) from error
            raise

    def pop_opponent(self, rules_hash: str, user_id: str) -> tuple[str, dict[str, Any], str] | None:
        query: dict[str, Any] = {
            "KeyConditionExpression": Key("PK").eq(f"QUEUE#{rules_hash}"),
            "ConsistentRead": True,
        }
        now = int(datetime.now(UTC).timestamp())
        claimed_until = int((datetime.now(UTC) + _MATCHMAKING_WAIT_TTL).timestamp())
        while True:
            response = self._table.query(**query)
            for item in response.get("Items", []):
                if (
                    item["userId"] == user_id
                    or item.get("status") != "waiting"
                    or int(item.get("expiresAt", 0)) <= now
                ):
                    continue
                ticket_id = str(item["ticketId"])
                try:
                    self._client.transact_write_items(
                        TransactItems=[
                            {
                                "Update": {
                                    "TableName": self._table_name,
                                    "Key": _serialize({"PK": item["PK"], "SK": item["SK"]}),
                                    "UpdateExpression": (
                                        "SET #status = :claimed, expiresAt = :expiresAt"
                                    ),
                                    "ConditionExpression": (
                                        "userId = :userId AND ticketId = :ticketId "
                                        "AND #status = :waiting AND expiresAt > :now"
                                    ),
                                    "ExpressionAttributeNames": {"#status": "status"},
                                    "ExpressionAttributeValues": _serialize_values(
                                        {
                                            ":userId": item["userId"],
                                            ":ticketId": ticket_id,
                                            ":waiting": "waiting",
                                            ":claimed": "claimed",
                                            ":now": now,
                                            ":expiresAt": claimed_until,
                                        }
                                    ),
                                }
                            },
                            {
                                "Update": {
                                    "TableName": self._table_name,
                                    "Key": _serialize(
                                        {"PK": f"USER#{item['userId']}", "SK": "QUEUE"}
                                    ),
                                    "UpdateExpression": (
                                        "SET #status = :claimed, expiresAt = :expiresAt"
                                    ),
                                    "ConditionExpression": (
                                        "ticketId = :ticketId AND rulesHash = :rulesHash "
                                        "AND queueSk = :queueSk AND #status = :waiting"
                                    ),
                                    "ExpressionAttributeNames": {"#status": "status"},
                                    "ExpressionAttributeValues": _serialize_values(
                                        {
                                            ":ticketId": ticket_id,
                                            ":rulesHash": rules_hash,
                                            ":queueSk": item["SK"],
                                            ":waiting": "waiting",
                                            ":claimed": "claimed",
                                            ":expiresAt": claimed_until,
                                        }
                                    ),
                                }
                            },
                            {
                                "Update": {
                                    "TableName": self._table_name,
                                    "Key": _serialize(
                                        {
                                            "PK": f"USER#{item['userId']}",
                                            "SK": f"TICKET#{ticket_id}",
                                        }
                                    ),
                                    "UpdateExpression": (
                                        "SET #status = :claimed, expiresAt = :expiresAt"
                                    ),
                                    "ConditionExpression": (
                                        "#status = :waiting AND queueSk = :queueSk"
                                    ),
                                    "ExpressionAttributeNames": {"#status": "status"},
                                    "ExpressionAttributeValues": _serialize_values(
                                        {
                                            ":claimed": "claimed",
                                            ":waiting": "waiting",
                                            ":queueSk": item["SK"],
                                            ":expiresAt": claimed_until,
                                        }
                                    ),
                                }
                            },
                        ]
                    )
                    return (
                        str(item["userId"]),
                        json.loads(item["rules"]),
                        ticket_id,
                    )
                except ClientError as error:
                    if error.response["Error"]["Code"] == "TransactionCanceledException":
                        continue
                    raise
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                break
            query["ExclusiveStartKey"] = last_key
        return None

    def active_matchmaking(self, user_id: str) -> MatchmakingRecord | None:
        response = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": "QUEUE"}, ConsistentRead=True
        )
        item = response.get("Item")
        if not item:
            return None
        now = int(datetime.now(UTC).timestamp())
        if int(item.get("expiresAt", 0)) <= now:
            self._delete_expired_queue(user_id, item, now)
            return None
        raw_status = item.get("status")
        if raw_status == "claimed":
            status: Literal["waiting", "claimed", "matched"] = "claimed"
        elif raw_status == "waiting":
            status = "waiting"
        else:
            return None
        return MatchmakingRecord(
            ticket_id=str(item["ticketId"]),
            status=status,
            rules_hash=str(item["rulesHash"]),
            queue_sk=str(item["queueSk"]),
            match_id=None,
            expires_at=datetime.fromtimestamp(int(item["expiresAt"]), UTC),
        )

    def matchmaking_status(self, user_id: str, ticket_id: str) -> MatchmakingRecord | None:
        response = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": f"TICKET#{ticket_id}"},
            ConsistentRead=True,
        )
        item = response.get("Item")
        if not item:
            return None
        expires_at = int(item.get("expiresAt", 0))
        now = int(datetime.now(UTC).timestamp())
        if expires_at <= now:
            try:
                self._table.delete_item(
                    Key={"PK": f"USER#{user_id}", "SK": f"TICKET#{ticket_id}"},
                    ConditionExpression=("ticketId = :ticketId AND expiresAt <= :now"),
                    ExpressionAttributeValues={
                        ":ticketId": ticket_id,
                        ":now": now,
                    },
                )
            except ClientError as error:
                if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                    return self.matchmaking_status(user_id, ticket_id)
                raise
            return None
        raw_status = item.get("status")
        if raw_status == "waiting":
            status: Literal["waiting", "claimed", "matched"] = "waiting"
        elif raw_status == "claimed":
            status = "claimed"
        elif raw_status == "matched":
            status = "matched"
        else:
            return None
        return MatchmakingRecord(
            ticket_id=ticket_id,
            status=status,
            rules_hash=item.get("rulesHash"),
            queue_sk=item.get("queueSk"),
            match_id=item.get("matchId"),
            expires_at=datetime.fromtimestamp(expires_at, UTC),
        )

    def commit_quick_match(
        self,
        match: StoredMatch,
        joining_user_id: str,
        requester_ticket_id: str,
        opponent_ticket_id: str,
    ) -> None:
        opponent_id = match.creator_id
        pointer = self._table.get_item(
            Key={"PK": f"USER#{opponent_id}", "SK": "QUEUE"},
            ConsistentRead=True,
        ).get("Item")
        if (
            not pointer
            or pointer.get("ticketId") != opponent_ticket_id
            or pointer.get("status") != "claimed"
        ):
            raise ApiError(
                "matchmakingConflict",
                "The opponent is no longer reserved for this match.",
                status_code=409,
            )
        rules_hash = str(pointer["rulesHash"])
        queue_sk = str(pointer["queueSk"])
        expires_at = int((datetime.now(UTC) + _MATCHMAKING_RESULT_TTL).timestamp())
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(self._match_item(match)),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"JOIN#{match.join_code}",
                                    "SK": "JOIN",
                                    "entity": "joinCode",
                                    "matchId": match.id,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{opponent_id}",
                                    "SK": f"MATCH#{match.id}",
                                    "entity": "membership",
                                    "matchId": match.id,
                                }
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{joining_user_id}",
                                    "SK": f"MATCH#{match.id}",
                                    "entity": "membership",
                                    "matchId": match.id,
                                }
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"QUEUE#{rules_hash}", "SK": queue_sk}),
                            "ConditionExpression": ("ticketId = :ticketId AND #status = :claimed"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":ticketId": opponent_ticket_id,
                                    ":claimed": "claimed",
                                }
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"USER#{opponent_id}", "SK": "QUEUE"}),
                            "ConditionExpression": (
                                "ticketId = :ticketId AND queueSk = :queueSk AND #status = :claimed"
                            ),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":ticketId": opponent_ticket_id,
                                    ":queueSk": queue_sk,
                                    ":claimed": "claimed",
                                }
                            ),
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize(
                                {
                                    "PK": f"USER#{opponent_id}",
                                    "SK": f"TICKET#{opponent_ticket_id}",
                                }
                            ),
                            "UpdateExpression": (
                                "SET #status = :matched, matchId = :matchId, expiresAt = :expiresAt"
                            ),
                            "ConditionExpression": ("#status = :claimed AND queueSk = :queueSk"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":matched": "matched",
                                    ":claimed": "claimed",
                                    ":queueSk": queue_sk,
                                    ":matchId": match.id,
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                    {
                        "Put": {
                            "TableName": self._table_name,
                            "Item": _serialize(
                                {
                                    "PK": f"USER#{joining_user_id}",
                                    "SK": f"TICKET#{requester_ticket_id}",
                                    "entity": "matchmakingTicket",
                                    "ticketId": requester_ticket_id,
                                    "status": "matched",
                                    "rulesHash": rules_hash,
                                    "matchId": match.id,
                                    "expiresAt": expires_at,
                                }
                            ),
                            "ConditionExpression": "attribute_not_exists(PK)",
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                existing = self.matchmaking_status(joining_user_id, requester_ticket_id)
                if existing is not None and existing.match_id == match.id:
                    return
                raise ApiError(
                    "matchmakingConflict",
                    "The quick match could not be committed.",
                    status_code=409,
                ) from error
            raise

    def release_matchmaking_claim(self, user_id: str, ticket_id: str) -> None:
        pointer = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": "QUEUE"}, ConsistentRead=True
        ).get("Item")
        if (
            not pointer
            or pointer.get("ticketId") != ticket_id
            or pointer.get("status") != "claimed"
        ):
            return
        expires_at = int((datetime.now(UTC) + _MATCHMAKING_WAIT_TTL).timestamp())
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize(
                                {
                                    "PK": f"QUEUE#{pointer['rulesHash']}",
                                    "SK": pointer["queueSk"],
                                }
                            ),
                            "UpdateExpression": ("SET #status = :waiting, expiresAt = :expiresAt"),
                            "ConditionExpression": ("ticketId = :ticketId AND #status = :claimed"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":claimed": "claimed",
                                    ":ticketId": ticket_id,
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize({"PK": f"USER#{user_id}", "SK": "QUEUE"}),
                            "UpdateExpression": ("SET #status = :waiting, expiresAt = :expiresAt"),
                            "ConditionExpression": (
                                "ticketId = :ticketId AND queueSk = :queueSk AND #status = :claimed"
                            ),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":claimed": "claimed",
                                    ":ticketId": ticket_id,
                                    ":queueSk": pointer["queueSk"],
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                    {
                        "Update": {
                            "TableName": self._table_name,
                            "Key": _serialize(
                                {
                                    "PK": f"USER#{user_id}",
                                    "SK": f"TICKET#{ticket_id}",
                                }
                            ),
                            "UpdateExpression": ("SET #status = :waiting, expiresAt = :expiresAt"),
                            "ConditionExpression": ("queueSk = :queueSk AND #status = :claimed"),
                            "ExpressionAttributeNames": {"#status": "status"},
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":waiting": "waiting",
                                    ":claimed": "claimed",
                                    ":queueSk": pointer["queueSk"],
                                    ":expiresAt": expires_at,
                                }
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "TransactionCanceledException":
                raise

    def remove_from_queue(self, user_id: str, ticket_id: str) -> bool:
        response = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": "QUEUE"}, ConsistentRead=True
        )
        pointer = response.get("Item")
        if pointer and pointer.get("ticketId") == ticket_id:
            try:
                self._client.transact_write_items(
                    TransactItems=[
                        {
                            "Delete": {
                                "TableName": self._table_name,
                                "Key": _serialize(
                                    {
                                        "PK": f"QUEUE#{pointer['rulesHash']}",
                                        "SK": pointer["queueSk"],
                                    }
                                ),
                                "ConditionExpression": (
                                    "ticketId = :ticketId AND #status IN (:waiting, :claimed)"
                                ),
                                "ExpressionAttributeNames": {"#status": "status"},
                                "ExpressionAttributeValues": _serialize_values(
                                    {
                                        ":ticketId": ticket_id,
                                        ":waiting": "waiting",
                                        ":claimed": "claimed",
                                    }
                                ),
                            }
                        },
                        {
                            "Delete": {
                                "TableName": self._table_name,
                                "Key": _serialize({"PK": f"USER#{user_id}", "SK": "QUEUE"}),
                                "ConditionExpression": (
                                    "ticketId = :ticketId AND queueSk = :queueSk "
                                    "AND #status IN (:waiting, :claimed)"
                                ),
                                "ExpressionAttributeNames": {"#status": "status"},
                                "ExpressionAttributeValues": _serialize_values(
                                    {
                                        ":ticketId": ticket_id,
                                        ":queueSk": pointer["queueSk"],
                                        ":waiting": "waiting",
                                        ":claimed": "claimed",
                                    }
                                ),
                            }
                        },
                    ]
                )
                try:
                    self._table.delete_item(
                        Key={
                            "PK": f"USER#{user_id}",
                            "SK": f"TICKET#{ticket_id}",
                        },
                        ConditionExpression="#status IN (:waiting, :claimed)",
                        ExpressionAttributeNames={"#status": "status"},
                        ExpressionAttributeValues={
                            ":waiting": "waiting",
                            ":claimed": "claimed",
                        },
                    )
                except ClientError as error:
                    if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                        raise
                return True
            except ClientError as error:
                if error.response["Error"]["Code"] != "TransactionCanceledException":
                    raise
        return False

    def _delete_expired_queue(
        self,
        user_id: str,
        pointer: dict[str, Any],
        now: int,
    ) -> None:
        ticket_id = str(pointer["ticketId"])
        targets = [
            {
                "PK": f"QUEUE#{pointer['rulesHash']}",
                "SK": str(pointer["queueSk"]),
            },
            {"PK": f"USER#{user_id}", "SK": "QUEUE"},
            {"PK": f"USER#{user_id}", "SK": f"TICKET#{ticket_id}"},
        ]
        for key in targets:
            try:
                self._table.delete_item(
                    Key=key,
                    ConditionExpression="ticketId = :ticketId AND expiresAt <= :now",
                    ExpressionAttributeValues={
                        ":ticketId": ticket_id,
                        ":now": now,
                    },
                )
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise

    def acquire_matchmaking_lock(self, user_id: str) -> str | None:
        token = secrets.token_urlsafe(18)
        now = int(datetime.now(UTC).timestamp())
        try:
            self._table.put_item(
                Item={
                    "PK": f"USER#{user_id}",
                    "SK": "MATCHMAKING_LOCK",
                    "entity": "matchmakingLock",
                    "token": token,
                    "expiresAt": int((datetime.now(UTC) + timedelta(seconds=30)).timestamp()),
                },
                ConditionExpression="attribute_not_exists(PK) OR expiresAt < :now",
                ExpressionAttributeValues={":now": now},
            )
            return token
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return None
            raise

    def release_matchmaking_lock(self, user_id: str, token: str) -> None:
        try:
            self._table.delete_item(
                Key={"PK": f"USER#{user_id}", "SK": "MATCHMAKING_LOCK"},
                ConditionExpression="#token = :token",
                ExpressionAttributeNames={"#token": "token"},
                ExpressionAttributeValues={":token": token},
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def put_exchange(self, exchange: StoredExchange) -> None:
        self._table.put_item(
            Item={
                "PK": f"OAUTH#{exchange.code}",
                "SK": "TOKEN",
                "entity": "oauthExchange",
                "document": exchange.model_dump_json(by_alias=True),
                "expiresAt": int(exchange.expires_at.timestamp()),
            }
        )

    def consume_exchange(self, code: str) -> StoredExchange | None:
        response = self._table.delete_item(
            Key={"PK": f"OAUTH#{code}", "SK": "TOKEN"},
            ReturnValues="ALL_OLD",
        )
        item = response.get("Attributes")
        if not item:
            return None
        exchange = StoredExchange.model_validate_json(item["document"])
        return exchange if exchange.expires_at > datetime.now(UTC) else None

    def put_oauth_transaction(self, transaction: StoredOAuthTransaction) -> None:
        self._table.put_item(
            Item={
                "PK": f"OAUTH_TX#{transaction.id}",
                "SK": "STATE",
                "entity": "oauthTransaction",
                "document": transaction.model_dump_json(by_alias=True),
                "expiresAt": int(transaction.expires_at.timestamp()),
            },
            ConditionExpression="attribute_not_exists(PK)",
        )

    def consume_oauth_transaction(self, transaction_id: str) -> StoredOAuthTransaction | None:
        response = self._table.delete_item(
            Key={"PK": f"OAUTH_TX#{transaction_id}", "SK": "STATE"},
            ReturnValues="ALL_OLD",
        )
        item = response.get("Attributes")
        if not item:
            return None
        transaction = StoredOAuthTransaction.model_validate_json(item["document"])
        return transaction if transaction.expires_at > datetime.now(UTC) else None

    def upsert_push_subscription(
        self, subscription: StoredPushSubscription
    ) -> StoredPushSubscription:
        subscription_key = {
            "PK": f"USER#{subscription.user_id}",
            "SK": f"PUSH#{subscription.installation_id}",
        }
        existing_item = self._table.get_item(
            Key=subscription_key,
            ConsistentRead=True,
        ).get("Item")
        existing = (
            StoredPushSubscription.model_validate_json(existing_item["document"])
            if existing_item
            else None
        )
        stored = subscription.model_copy(
            update={"created_at": existing.created_at if existing else subscription.created_at}
        )
        owner_key = {
            "PK": f"INSTALLATION#{subscription.installation_id}",
            "SK": "OWNER",
        }
        previous_owner = self._table.get_item(
            Key=owner_key,
            ConsistentRead=True,
        ).get("Item")
        owner_condition = "attribute_not_exists(PK)"
        owner_values: dict[str, Any] = {}
        if previous_owner is not None:
            owner_condition = "userId = :previousUser AND installationId = :installationId"
            owner_values = {
                ":previousUser": str(previous_owner["userId"]),
                ":installationId": subscription.installation_id,
            }

        transaction: list[dict[str, Any]] = []
        transaction.append(
            {
                "ConditionCheck": {
                    "TableName": self._table_name,
                    "Key": _serialize(
                        {"PK": f"USER#{subscription.user_id}", "SK": "ACCOUNT_DELETED"}
                    ),
                    "ConditionExpression": "attribute_not_exists(PK)",
                }
            }
        )
        if previous_owner is not None and previous_owner["userId"] != subscription.user_id:
            transaction.append(
                {
                    "Delete": {
                        "TableName": self._table_name,
                        "Key": _serialize(
                            {
                                "PK": f"USER#{previous_owner['userId']}",
                                "SK": f"PUSH#{subscription.installation_id}",
                            }
                        ),
                    }
                }
            )
        transaction.extend(
            [
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **subscription_key,
                                "entity": "pushSubscription",
                                "userId": subscription.user_id,
                                "installationId": subscription.installation_id,
                                "document": stored.model_dump_json(by_alias=True),
                            }
                        ),
                    }
                },
                {
                    "Put": {
                        "TableName": self._table_name,
                        "Item": _serialize(
                            {
                                **owner_key,
                                "entity": "pushInstallationOwner",
                                "userId": subscription.user_id,
                                "installationId": subscription.installation_id,
                            }
                        ),
                        "ConditionExpression": owner_condition,
                        **(
                            {"ExpressionAttributeValues": _serialize_values(owner_values)}
                            if owner_values
                            else {}
                        ),
                    }
                },
            ]
        )
        try:
            self._client.transact_write_items(TransactItems=transaction)
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                raise ApiError(
                    "pushSubscriptionConflict",
                    "The push subscription changed during registration. Try again.",
                    status_code=409,
                ) from error
            raise
        return stored

    def list_push_subscriptions(self, user_id: str) -> list[StoredPushSubscription]:
        items = self._partition_items(f"USER#{user_id}", sk_prefix="PUSH#")
        subscriptions = [
            StoredPushSubscription.model_validate_json(item["document"]) for item in items
        ]
        return sorted(subscriptions, key=lambda value: value.created_at)

    def get_push_subscription(
        self, user_id: str, installation_id: str
    ) -> StoredPushSubscription | None:
        item = self._table.get_item(
            Key={"PK": f"USER#{user_id}", "SK": f"PUSH#{installation_id}"},
            ConsistentRead=True,
        ).get("Item")
        if item is None:
            return None
        return StoredPushSubscription.model_validate_json(item["document"])

    def delete_push_subscription(self, user_id: str, installation_id: str) -> None:
        subscription_key = {"PK": f"USER#{user_id}", "SK": f"PUSH#{installation_id}"}
        owner_key = {"PK": f"INSTALLATION#{installation_id}", "SK": "OWNER"}
        owner = self._table.get_item(Key=owner_key, ConsistentRead=True).get("Item")
        if owner is None or owner.get("userId") != user_id:
            self._table.delete_item(Key=subscription_key)
            return
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(subscription_key),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(owner_key),
                            "ConditionExpression": (
                                "userId = :userId AND installationId = :installationId"
                            ),
                            "ExpressionAttributeValues": _serialize_values(
                                {":userId": user_id, ":installationId": installation_id}
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                return
            raise

    def delete_push_subscription_if_unchanged(self, subscription: StoredPushSubscription) -> bool:
        subscription_key = {
            "PK": f"USER#{subscription.user_id}",
            "SK": f"PUSH#{subscription.installation_id}",
        }
        owner_key = {"PK": f"INSTALLATION#{subscription.installation_id}", "SK": "OWNER"}
        try:
            self._client.transact_write_items(
                TransactItems=[
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(subscription_key),
                            "ConditionExpression": "document = :document",
                            "ExpressionAttributeValues": _serialize_values(
                                {":document": subscription.model_dump_json(by_alias=True)}
                            ),
                        }
                    },
                    {
                        "Delete": {
                            "TableName": self._table_name,
                            "Key": _serialize(owner_key),
                            "ConditionExpression": (
                                "userId = :userId AND installationId = :installationId"
                            ),
                            "ExpressionAttributeValues": _serialize_values(
                                {
                                    ":userId": subscription.user_id,
                                    ":installationId": subscription.installation_id,
                                }
                            ),
                        }
                    },
                ]
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "TransactionCanceledException":
                return False
            raise
        return True

    def claim_notification_delivery(self, delivery_id: str) -> str | None:
        now = datetime.now(UTC)
        claim_token = secrets.token_urlsafe(18)
        try:
            self._table.put_item(
                Item={
                    "PK": f"DELIVERY#{delivery_id}",
                    "SK": "STATE",
                    "entity": "notificationDelivery",
                    "status": "sending",
                    "claimToken": claim_token,
                    "leaseExpiresAt": int((now + timedelta(minutes=5)).timestamp()),
                    "expiresAt": int((now + timedelta(days=7)).timestamp()),
                },
                ConditionExpression=(
                    "attribute_not_exists(PK) OR (#status = :sending AND leaseExpiresAt < :now)"
                ),
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={":sending": "sending", ":now": int(now.timestamp())},
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return None
            raise
        return claim_token

    def complete_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        try:
            self._table.update_item(
                Key={"PK": f"DELIVERY#{delivery_id}", "SK": "STATE"},
                UpdateExpression=(
                    "SET #status = :delivered, expiresAt = :expiresAt REMOVE leaseExpiresAt"
                ),
                ConditionExpression="#status = :sending AND claimToken = :claimToken",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={
                    ":delivered": "delivered",
                    ":sending": "sending",
                    ":claimToken": claim_token,
                    ":expiresAt": int((datetime.now(UTC) + timedelta(days=7)).timestamp()),
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def release_notification_delivery(self, delivery_id: str, claim_token: str) -> None:
        try:
            self._table.delete_item(
                Key={"PK": f"DELIVERY#{delivery_id}", "SK": "STATE"},
                ConditionExpression="#status = :sending AND claimToken = :claimToken",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={
                    ":sending": "sending",
                    ":claimToken": claim_token,
                },
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def delete_user_data(self, user_id: str) -> None:
        user_items = self._partition_items(f"USER#{user_id}")
        matches = [
            match
            for item in user_items
            if item.get("entity") == "membership"
            if (match := self.get_match(str(item["matchId"]))) is not None
        ]
        if any(match.status != MatchStatus.completed for match in matches):
            raise ApiError(
                "accountDeletionConflict",
                "All active matches must end before account data can be deleted.",
                status_code=409,
            )

        # Fence new notification registrations before the final consistent
        # sweep. The registration transaction condition-checks this item, so a
        # request racing deletion either commits before the fence and is swept,
        # or fails after it. DynamoDB removes the minimal guard after its TTL.
        deletion_guard = {
            "PK": f"USER#{user_id}",
            "SK": "ACCOUNT_DELETED",
            "entity": "accountDeletionGuard",
            "expiresAt": int((datetime.now(UTC) + timedelta(days=1)).timestamp()),
        }
        self._table.put_item(Item=deletion_guard)
        user_items = self._partition_items(f"USER#{user_id}")

        for match in matches:
            anonymous_id = f"deleted-{uuid4()}"
            anonymized = _anonymize_match(match, user_id, anonymous_id)
            if anonymized != match:
                self._table.put_item(Item=self._match_item(anonymized))
            for item in self._partition_items(f"MATCH#{match.id}", sk_prefix="MOVE#"):
                move = MoveEvent.model_validate_json(item["document"])
                anonymized_move = _anonymize_move(move, user_id, anonymous_id)
                if anonymized_move != move:
                    self._table.put_item(
                        Item={
                            **item,
                            "document": anonymized_move.model_dump_json(by_alias=True),
                        }
                    )

        queue_pointer = next(
            (item for item in user_items if item.get("entity") == "queuePointer"),
            None,
        )
        if queue_pointer is not None:
            self._table.delete_item(
                Key={
                    "PK": f"QUEUE#{queue_pointer['rulesHash']}",
                    "SK": str(queue_pointer["queueSk"]),
                }
            )

        for subscription_item in (
            item for item in user_items if item.get("entity") == "pushSubscription"
        ):
            try:
                self._table.delete_item(
                    Key={
                        "PK": f"INSTALLATION#{subscription_item['installationId']}",
                        "SK": "OWNER",
                    },
                    ConditionExpression="userId = :userId",
                    ExpressionAttributeValues={":userId": user_id},
                )
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise

        self._delete_items(self._partition_items(f"IDEMP#{user_id}"))
        self._delete_items([item for item in user_items if item.get("SK") != "ACCOUNT_DELETED"])

    def _partition_items(
        self,
        partition_key: str,
        *,
        sk_prefix: str | None = None,
    ) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        expression = Key("PK").eq(partition_key)
        if sk_prefix is not None:
            expression &= Key("SK").begins_with(sk_prefix)
        query: dict[str, Any] = {
            "KeyConditionExpression": expression,
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**query)
            items.extend(response.get("Items", []))
            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                return items
            query["ExclusiveStartKey"] = last_key

    def _delete_items(self, items: list[dict[str, Any]]) -> None:
        for item in items:
            self._table.delete_item(Key={"PK": item["PK"], "SK": item["SK"]})


def _serialize(item: dict[str, Any]) -> dict[str, Any]:
    from boto3.dynamodb.types import TypeSerializer

    serializer = TypeSerializer()
    return {key: serializer.serialize(value) for key, value in item.items()}


def _serialize_values(item: dict[str, Any]) -> dict[str, Any]:
    return _serialize(item)


def _anonymize_match(match: StoredMatch, user_id: str, anonymous_id: str) -> StoredMatch:
    update: dict[str, Any] = {}
    if match.creator_id == user_id:
        update["creator_id"] = anonymous_id
        update["creator_name"] = "Deleted player"
    if match.black_player is not None and match.black_player.id == user_id:
        update["black_player"] = PlayerSummary(
            id=anonymous_id,
            display_name="Deleted player",
        )
    if match.white_player is not None and match.white_player.id == user_id:
        update["white_player"] = PlayerSummary(
            id=anonymous_id,
            display_name="Deleted player",
        )
    if not update:
        return match
    update["version"] = match.version + 1
    update["updated_at"] = datetime.now(UTC)
    return match.model_copy(update=update, deep=True)


def _anonymize_move(move: MoveEvent, user_id: str, anonymous_id: str) -> MoveEvent:
    if move.actor_id != user_id:
        return move
    return move.model_copy(update={"actor_id": anonymous_id}, deep=True)


def build_repository(settings: Settings) -> Repository:
    if settings.is_production:
        return DynamoRepository(settings)
    return InMemoryRepository()

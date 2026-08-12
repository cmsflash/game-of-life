from __future__ import annotations

from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from life_api.models import MatchStatus, StoredMatch, StoredOAuthTransaction


def test_persisted_timestamps_normalize_offsets_to_utc() -> None:
    transaction = StoredOAuthTransaction.model_validate(
        {
            "id": "transaction-id",
            "verifier": "verifier",
            "returnTo": "com.cmsflash.gameoflife://auth",
            "expiresAt": "2026-07-29T08:30:00+08:00",
        }
    )

    assert transaction.expires_at == datetime(2026, 7, 29, 0, 30, tzinfo=UTC)
    assert transaction.model_dump(mode="json", by_alias=True)["expiresAt"] == (
        "2026-07-29T00:30:00Z"
    )


def test_persisted_timestamps_reject_ambiguous_naive_values() -> None:
    with pytest.raises(ValidationError, match="datetime must include a timezone"):
        StoredMatch(
            id="00000000-0000-0000-0000-000000000001",
            join_code="ABC123",
            rules={},
            state={"revision": 0},
            creator_id="user-id",
            creator_name="Player",
            status=MatchStatus.waiting,
            created_at=datetime(2026, 7, 29, 0, 30),
        )


def test_stored_match_accepts_legacy_documents_without_last_move() -> None:
    match = StoredMatch.model_validate(
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "joinCode": "ABC123",
            "rules": {},
            "state": {"revision": 0},
            "creatorId": "user-id",
            "creatorName": "Player",
            "status": "waiting",
            "createdAt": "2026-07-29T00:30:00Z",
            "updatedAt": "2026-07-29T00:30:00Z",
        }
    )

    assert match.last_move is None
    assert match.model_dump(mode="json", by_alias=True)["lastMove"] is None

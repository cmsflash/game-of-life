from __future__ import annotations

from typing import Any

from conftest import register_and_login
from fastapi.testclient import TestClient


def _assert_match_etag(response: Any, version: int) -> str:
    etag = str(response.headers["etag"])
    assert etag.startswith(f'"{version}-p')
    assert etag.endswith('"')
    assert len(etag) == len(str(version)) + 20
    return etag


def _create_active_match(
    client: TestClient,
) -> tuple[dict[str, Any], dict[str, str], dict[str, str]]:
    _, alice_auth = register_and_login(
        client,
        "alice",
        display_name="Alice Strategist",
    )
    _, bob_auth = register_and_login(
        client,
        "bob",
        display_name="Bob Builder",
    )
    alice_headers = {"Authorization": alice_auth}
    bob_headers = {"Authorization": bob_auth}
    created = client.post("/v1/matches", json={}, headers=alice_headers)
    assert created.status_code == 201
    _assert_match_etag(created, 0)
    waiting = created.json()
    joined = client.post(
        "/v1/matches/join",
        json={"joinCode": waiting["joinCode"]},
        headers=bob_headers,
    )
    assert joined.status_code == 200
    _assert_match_etag(joined, 1)
    document = joined.json()
    assert {
        document["blackPlayer"]["displayName"],
        document["whitePlayer"]["displayName"],
    } == {"Alice Strategist", "Bob Builder"}
    assert "email" not in document["blackPlayer"]
    assert "username" not in document["blackPlayer"]
    assert "email" not in document["whitePlayer"]
    assert "username" not in document["whitePlayer"]
    return document, alice_headers, bob_headers


def test_private_match_move_idempotency_etag_history_replay_and_resign(
    client: TestClient,
) -> None:
    match, alice_headers, bob_headers = _create_active_match(client)
    match_id = match["id"]
    assert match["status"] == "active"
    alice = client.get(f"/v1/matches/{match_id}", headers=alice_headers).json()
    black_headers = alice_headers if alice["yourColor"] == "black" else bob_headers
    white_headers = bob_headers if black_headers is alice_headers else alice_headers

    moved = client.post(
        f"/v1/matches/{match_id}/moves",
        headers=black_headers,
        json={
            "row": 0,
            "column": 0,
            "expectedRevision": 0,
            "idempotencyKey": "move-00000001",
        },
    )
    assert moved.status_code == 200
    moved_etag = _assert_match_etag(moved, 2)
    assert moved.json()["state"]["revision"] == 1
    assert moved.json()["lastMove"] == {
        "revision": 1,
        "player": "black",
        "row": 0,
        "column": 0,
    }
    repeated = client.post(
        f"/v1/matches/{match_id}/moves",
        headers=black_headers,
        json={
            "row": 0,
            "column": 0,
            "expectedRevision": 0,
            "idempotencyKey": "move-00000001",
        },
    )
    assert repeated.status_code == 200
    assert repeated.headers["etag"] == moved_etag
    assert repeated.json()["state"]["revision"] == 1
    assert repeated.json()["lastMove"] == moved.json()["lastMove"]
    conflicting_reuse = client.post(
        f"/v1/matches/{match_id}/moves",
        headers=black_headers,
        json={
            "row": 0,
            "column": 2,
            "expectedRevision": 0,
            "idempotencyKey": "move-00000001",
        },
    )
    assert conflicting_reuse.status_code == 409
    assert conflicting_reuse.json()["error"]["code"] == "idempotencyConflict"

    wrong_turn = client.post(
        f"/v1/matches/{match_id}/moves",
        headers=black_headers,
        json={
            "row": 0,
            "column": 1,
            "expectedRevision": 1,
            "idempotencyKey": "move-00000002",
        },
    )
    assert wrong_turn.status_code == 409
    assert wrong_turn.json()["error"]["code"] == "wrongPlayer"

    current = client.get(f"/v1/matches/{match_id}", headers=white_headers)
    assert current.status_code == 200
    assert current.headers["etag"] == moved_etag
    assert current.json()["lastMove"] == moved.json()["lastMove"]
    unchanged = client.get(
        f"/v1/matches/{match_id}",
        headers={**white_headers, "If-None-Match": moved_etag},
    )
    assert unchanged.status_code == 304

    history = client.get(f"/v1/matches/{match_id}/moves", headers=alice_headers)
    assert history.status_code == 200
    assert [item["revision"] for item in history.json()["items"]] == [1]
    replay = client.get(f"/v1/matches/{match_id}/replay", headers=alice_headers)
    assert replay.status_code == 200
    assert replay.json()["finalState"]["revision"] == 1

    resigned = client.post(
        f"/v1/matches/{match_id}/resign",
        headers=white_headers,
        json={"expectedRevision": 1, "idempotencyKey": "resign-000001"},
    )
    assert resigned.status_code == 200
    resigned_etag = _assert_match_etag(resigned, 3)
    assert resigned.json()["status"] == "completed"
    assert resigned.json()["lastMove"] == moved.json()["lastMove"]
    assert resigned.json()["result"] == {
        "type": "win",
        "winner": "black",
        "reason": "resignation",
    }
    changed_after_resignation = client.get(
        f"/v1/matches/{match_id}",
        headers={**white_headers, "If-None-Match": moved_etag},
    )
    assert changed_after_resignation.status_code == 200
    assert changed_after_resignation.headers["etag"] == resigned_etag
    repeated_resignation = client.post(
        f"/v1/matches/{match_id}/resign",
        headers=white_headers,
        json={"expectedRevision": 1, "idempotencyKey": "resign-000001"},
    )
    assert repeated_resignation.status_code == 200
    assert repeated_resignation.headers["etag"] == resigned_etag
    assert repeated_resignation.json()["version"] == 3


def test_stale_revision_and_match_authorization(client: TestClient) -> None:
    match, alice_headers, bob_headers = _create_active_match(client)
    match_id = match["id"]
    alice = client.get(f"/v1/matches/{match_id}", headers=alice_headers).json()
    black_headers = alice_headers if alice["yourColor"] == "black" else bob_headers
    stale = client.post(
        f"/v1/matches/{match_id}/moves",
        headers=black_headers,
        json={
            "row": 1,
            "column": 1,
            "expectedRevision": 9,
            "idempotencyKey": "stale-000001",
        },
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["details"] == {"currentRevision": 0}

    _, eve_auth = register_and_login(client, "eve")
    forbidden = client.get(
        f"/v1/matches/{match_id}",
        headers={"Authorization": eve_auth},
    )
    assert forbidden.status_code == 403


def test_match_etag_changes_with_current_public_display_name(client: TestClient) -> None:
    match, alice_headers, _ = _create_active_match(client)
    first = client.get(f"/v1/matches/{match['id']}", headers=alice_headers)
    first_etag = first.headers["etag"]
    alice = next(
        player
        for player in (first.json()["blackPlayer"], first.json()["whitePlayer"])
        if player["displayName"] == "Alice Strategist"
    )
    repository = client.app.state.services.repository
    profile = repository.get_public_player(alice["id"])
    assert profile is not None
    repository.upsert_public_player(
        profile.model_copy(
            update={
                "display_name": "Alice Renamed",
                "normalized_display_name": "alice renamed",
            }
        )
    )

    changed = client.get(
        f"/v1/matches/{match['id']}",
        headers={**alice_headers, "If-None-Match": first_etag},
    )
    assert changed.status_code == 200
    assert changed.headers["etag"] != first_etag
    assert any(
        player["displayName"] == "Alice Renamed"
        for player in (changed.json()["blackPlayer"], changed.json()["whitePlayer"])
    )
    unchanged = client.get(
        f"/v1/matches/{match['id']}",
        headers={**alice_headers, "If-None-Match": changed.headers["etag"]},
    )
    assert unchanged.status_code == 304


def test_match_list_preserves_all_memberships_beyond_fifty(client: TestClient) -> None:
    _, alice_auth = register_and_login(client, "alice", display_name="Alice Strategist")
    _, bob_auth = register_and_login(client, "bob", display_name="Bob Builder")
    alice_headers = {"Authorization": alice_auth}
    bob_headers = {"Authorization": bob_auth}
    match_ids: list[str] = []
    for _ in range(51):
        created = client.post("/v1/matches", json={}, headers=alice_headers)
        assert created.status_code == 201
        joined = client.post(
            "/v1/matches/join",
            json={"joinCode": created.json()["joinCode"]},
            headers=bob_headers,
        )
        assert joined.status_code == 200
        match_ids.append(str(joined.json()["id"]))

    for index, match_id in enumerate(match_ids[:2]):
        completed = client.post(
            f"/v1/matches/{match_id}/resign",
            json={
                "expectedRevision": 0,
                "idempotencyKey": f"bulk-resign-{index:08d}",
            },
            headers=bob_headers,
        )
        assert completed.status_code == 200

    response = client.get("/v1/matches", headers=alice_headers)

    assert response.status_code == 200
    assert "nextToken" not in response.json()
    assert {item["id"] for item in response.json()["items"]} == set(match_ids)
    assert len(response.json()["items"]) == 51
    assert sum(item["status"] == "completed" for item in response.json()["items"]) == 2


def test_quick_match_pairs_compatible_players(client: TestClient) -> None:
    _, alice_auth = register_and_login(
        client,
        "alice",
        display_name="Alice Strategist",
    )
    _, bob_auth = register_and_login(
        client,
        "bob",
        display_name="Bob Builder",
    )
    alice_headers = {"Authorization": alice_auth}
    bob_headers = {"Authorization": bob_auth}

    alice_ticket = "ticket-alice-000001"
    bob_ticket = "ticket-bob-00000001"
    waiting = client.post(
        "/v1/matchmaking",
        json={"ticketId": alice_ticket},
        headers=alice_headers,
    )
    assert waiting.status_code == 200
    assert waiting.json() == {
        "ticketId": alice_ticket,
        "status": "waiting",
        "matchId": None,
    }
    matched = client.post(
        "/v1/matchmaking",
        json={"ticketId": bob_ticket},
        headers=bob_headers,
    )
    assert matched.status_code == 200
    assert matched.json()["ticketId"] == bob_ticket
    assert matched.json()["status"] == "matched"
    assert matched.json()["matchId"]
    quick_match = client.get(
        f"/v1/matches/{matched.json()['matchId']}",
        headers=bob_headers,
    ).json()
    assert {
        quick_match["blackPlayer"]["displayName"],
        quick_match["whitePlayer"]["displayName"],
    } == {"Alice Strategist", "Bob Builder"}
    alice_status = client.get(
        "/v1/matchmaking",
        params={"ticketId": alice_ticket},
        headers=alice_headers,
    )
    assert alice_status.json() == {
        "ticketId": alice_ticket,
        "status": "matched",
        "matchId": matched.json()["matchId"],
    }
    late_cancel = client.delete(
        "/v1/matchmaking",
        params={"ticketId": alice_ticket},
        headers=alice_headers,
    )
    assert late_cancel.status_code == 409
    assert late_cancel.json()["error"]["code"] == "matchAlreadyFound"
    assert late_cancel.json()["error"]["details"] == {"matchId": matched.json()["matchId"]}
    unknown_status = client.get(
        "/v1/matchmaking",
        params={"ticketId": "ticket-alice-unknown1"},
        headers=alice_headers,
    )
    assert unknown_status.status_code == 404
    assert unknown_status.json()["error"]["code"] == "matchmakingTicketNotFound"


def test_quick_match_retry_and_cancel_are_ticket_scoped(client: TestClient) -> None:
    _, alice_auth = register_and_login(client, "alice")
    headers = {"Authorization": alice_auth}
    ticket = "ticket-alice-000001"
    other_ticket = "ticket-alice-000002"

    started = client.post(
        "/v1/matchmaking",
        json={"ticketId": ticket},
        headers=headers,
    )
    retried = client.post(
        "/v1/matchmaking",
        json={"ticketId": ticket},
        headers=headers,
    )
    overlapping = client.post(
        "/v1/matchmaking",
        json={"ticketId": other_ticket},
        headers=headers,
    )

    assert started.json() == retried.json() == overlapping.json()
    assert started.json()["ticketId"] == ticket
    assert (
        client.delete(
            "/v1/matchmaking",
            params={"ticketId": other_ticket},
            headers=headers,
        ).status_code
        == 200
    )
    assert (
        client.get(
            "/v1/matchmaking",
            params={"ticketId": ticket},
            headers=headers,
        ).status_code
        == 200
    )
    assert (
        client.delete(
            "/v1/matchmaking",
            params={"ticketId": ticket},
            headers=headers,
        ).status_code
        == 200
    )
    cancelled = client.get(
        "/v1/matchmaking",
        params={"ticketId": ticket},
        headers=headers,
    )
    assert cancelled.status_code == 404


def test_creator_can_cancel_a_waiting_private_match(client: TestClient) -> None:
    _, alice_auth = register_and_login(client, "alice")
    _, bob_auth = register_and_login(client, "bob")
    alice_headers = {"Authorization": alice_auth}
    bob_headers = {"Authorization": bob_auth}
    created = client.post("/v1/matches", json={}, headers=alice_headers).json()

    assert client.delete(f"/v1/matches/{created['id']}", headers=bob_headers).status_code == 403
    cancelled = client.delete(f"/v1/matches/{created['id']}", headers=alice_headers)
    assert cancelled.status_code == 200
    assert client.get(f"/v1/matches/{created['id']}", headers=alice_headers).status_code == 404
    assert (
        client.post(
            "/v1/matches/join",
            json={"joinCode": created["joinCode"]},
            headers=bob_headers,
        ).status_code
        == 404
    )

from __future__ import annotations

from typing import Any

from conftest import register_and_login
from fastapi.testclient import TestClient


def _create_active_match(
    client: TestClient,
) -> tuple[dict[str, Any], dict[str, str], dict[str, str]]:
    _, alice_auth = register_and_login(client, "alice")
    _, bob_auth = register_and_login(client, "bob")
    alice_headers = {"Authorization": alice_auth}
    bob_headers = {"Authorization": bob_auth}
    created = client.post("/v1/matches", json={}, headers=alice_headers)
    assert created.status_code == 201
    assert created.headers["etag"] == '"0"'
    waiting = created.json()
    joined = client.post(
        "/v1/matches/join",
        json={"joinCode": waiting["joinCode"]},
        headers=bob_headers,
    )
    assert joined.status_code == 200
    assert joined.headers["etag"] == '"1"'
    document = joined.json()
    assert document["blackPlayer"]["displayName"] == "Black player"
    assert document["whitePlayer"]["displayName"] == "White player"
    assert {
        document["blackPlayer"]["displayName"],
        document["whitePlayer"]["displayName"],
    }.isdisjoint({"Alice", "Bob"})
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
    assert moved.headers["etag"] == '"2"'
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
    assert repeated.headers["etag"] == '"2"'
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
    assert current.headers["etag"] == '"2"'
    assert current.json()["lastMove"] == moved.json()["lastMove"]
    unchanged = client.get(
        f"/v1/matches/{match_id}",
        headers={**white_headers, "If-None-Match": '"2"'},
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
    assert resigned.headers["etag"] == '"3"'
    assert resigned.json()["status"] == "completed"
    assert resigned.json()["lastMove"] == moved.json()["lastMove"]
    assert resigned.json()["result"] == {
        "type": "win",
        "winner": "black",
        "reason": "resignation",
    }
    changed_after_resignation = client.get(
        f"/v1/matches/{match_id}",
        headers={**white_headers, "If-None-Match": '"2"'},
    )
    assert changed_after_resignation.status_code == 200
    assert changed_after_resignation.headers["etag"] == '"3"'
    repeated_resignation = client.post(
        f"/v1/matches/{match_id}/resign",
        headers=white_headers,
        json={"expectedRevision": 1, "idempotencyKey": "resign-000001"},
    )
    assert repeated_resignation.status_code == 200
    assert repeated_resignation.headers["etag"] == '"3"'
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


def test_quick_match_pairs_compatible_players(client: TestClient) -> None:
    _, alice_auth = register_and_login(client, "alice")
    _, bob_auth = register_and_login(client, "bob")
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
    assert quick_match["blackPlayer"]["displayName"] == "Black player"
    assert quick_match["whitePlayer"]["displayName"] == "White player"
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

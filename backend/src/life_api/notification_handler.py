from __future__ import annotations

import logging
from typing import Any, cast

from boto3.dynamodb.types import TypeDeserializer

from .models import StoredMatch, TurnNotificationJob
from .notifications import (
    TurnNotificationService,
    build_turn_notification_service,
    is_new_turn,
    turn_job_for_match,
)
from .settings import get_settings

LOGGER = logging.getLogger("life_api.notification_handler")
_SERVICE: TurnNotificationService | None = None


def handler(event: dict[str, Any], context: object) -> dict[str, Any]:
    del context
    records = event.get("Records")
    if isinstance(records, list):
        return _handle_stream(records)

    job = TurnNotificationJob.model_validate(event)
    _service().process_reminder(job)
    return {"processed": True}


def _handle_stream(records: list[dict[str, Any]]) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    for record in records:
        identifier = str(record.get("eventID", "unknown"))
        try:
            transition = _match_transition(record)
            if transition is None:
                continue
            previous, current = transition
            if not is_new_turn(previous, current):
                continue
            job = turn_job_for_match(current)
            if job is not None:
                _service().process_turn_start(job)
        except Exception:
            LOGGER.exception(
                "Turn-notification stream record failed", extra={"eventID": identifier}
            )
            failures.append({"itemIdentifier": identifier})
    return {"batchItemFailures": failures}


def _match_transition(
    record: dict[str, Any],
) -> tuple[StoredMatch | None, StoredMatch] | None:
    if record.get("eventName") == "REMOVE":
        return None
    dynamodb = record.get("dynamodb")
    if not isinstance(dynamodb, dict):
        return None
    new_image = _deserialize_image(dynamodb.get("NewImage"))
    if (
        new_image is None
        or new_image.get("entity") != "match"
        or not isinstance(new_image.get("document"), str)
    ):
        return None
    old_image = _deserialize_image(dynamodb.get("OldImage"))
    previous = None
    if old_image is not None and isinstance(old_image.get("document"), str):
        previous = StoredMatch.model_validate_json(old_image["document"])
    current = StoredMatch.model_validate_json(new_image["document"])
    return previous, current


def _deserialize_image(value: object) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    deserializer = TypeDeserializer()
    return {
        str(key): deserializer.deserialize(cast(dict[str, Any], attribute))
        for key, attribute in value.items()
    }


def _service() -> TurnNotificationService:
    global _SERVICE
    if _SERVICE is None:
        _SERVICE = build_turn_notification_service(get_settings())
    return _SERVICE

from __future__ import annotations

from pathlib import Path


def test_api_and_notification_roles_include_transaction_and_account_state_permissions() -> None:
    template = (Path(__file__).parents[2] / "infra" / "template.yaml").read_text()

    assert "dynamodb:ConditionCheckItem" in template
    worker_policy = template.split("PolicyName: NotificationWorker", maxsplit=1)[1]
    worker_read = worker_policy.split("- Sid: WriteNotificationState", maxsplit=1)[0]
    assert '- "ACCOUNT#*"' in worker_read


def test_api_role_cannot_scan_the_shared_scheduler_group() -> None:
    template = (Path(__file__).parents[2] / "infra" / "template.yaml").read_text()
    api_policy = template.split("Sid: GameTableReadWrite", maxsplit=1)[1].split(
        "NotificationDeadLetterQueue:", maxsplit=1
    )[0]

    assert "scheduler:ListSchedules" not in api_policy
    assert "scheduler:GetSchedule" not in api_policy
    assert "scheduler:DeleteSchedule" not in api_policy

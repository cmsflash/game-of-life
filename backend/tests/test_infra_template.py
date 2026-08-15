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


def test_avatar_storage_worker_and_alarms_are_private_and_cycle_safe() -> None:
    template = (Path(__file__).parents[2] / "infra" / "template.yaml").read_text()
    bucket = template.split("AvatarBucket:", maxsplit=1)[1].split(
        "AvatarCleanupDeadLetterQueue:", maxsplit=1
    )[0]
    worker = template.split("AvatarCleanupFunction:", maxsplit=1)[1].split(
        "NotificationDeadLetterQueue:", maxsplit=1
    )[0]

    assert "BlockPublicAcls: true" in bucket
    assert "RestrictPublicBuckets: true" in bucket
    assert "aws:SecureTransport: false" in bucket
    assert "Value: pending" in bucket and "Value: orphan" in bucket
    assert "DependsOn: AvatarCleanupFunctionLogGroup" in worker
    assert 'FunctionName: !Sub "life-${EnvironmentName}-avatar-cleanup"' in worker
    assert 'LogGroupName: !Sub "/aws/lambda/life-${EnvironmentName}-avatar-cleanup"' in worker
    assert "${AvatarCleanupFunction}" not in worker
    assert "AvatarCleanupFunctionErrorAlarm:" in template
    assert "AvatarCleanupDeadLetterQueueAlarm:" in template
    alarm_section = template.split("AvatarCleanupFunctionErrorAlarm:", maxsplit=1)[1].split(
        "ApiLatencyAlarm:", maxsplit=1
    )[0]
    assert alarm_section.count("!Ref AlarmTopic") >= 4


def test_web_csp_allows_only_the_configured_api_origin_for_avatars() -> None:
    template = (Path(__file__).parents[2] / "infra" / "web-template.yaml").read_text()

    assert "ApiOrigin:" in template
    assert "img-src 'self' data: blob: ${ApiOrigin};" in template
    assert "img-src 'self' data: blob: https:;" not in template

import importlib

from life_api import lambda_handler


def test_lambda_handler_uses_configured_api_gateway_base_path(
    monkeypatch,
) -> None:
    monkeypatch.setenv("API_GATEWAY_BASE_PATH", "/prod")

    reloaded = importlib.reload(lambda_handler)

    assert reloaded.handler.config["api_gateway_base_path"] == "/prod"


def test_lambda_handler_defaults_to_root_base_path(monkeypatch) -> None:
    monkeypatch.delenv("API_GATEWAY_BASE_PATH", raising=False)
    reloaded = importlib.reload(lambda_handler)

    assert reloaded.handler.config["api_gateway_base_path"] == "/"

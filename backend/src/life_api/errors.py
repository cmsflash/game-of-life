from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException


class ApiError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        status_code: int = 400,
        details: Any | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.details = details


def error_payload(
    code: str,
    message: str,
    *,
    details: Any | None = None,
    request_id: str | None = None,
) -> dict[str, Any]:
    error: dict[str, Any] = {"code": code, "message": message}
    if details is not None:
        error["details"] = details
    if request_id is not None:
        error["requestId"] = request_id
    return {"error": error}


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(HTTPException)
    async def http_error_handler(request: Request, exc: HTTPException) -> JSONResponse:
        code = {
            404: "notFound",
            405: "methodNotAllowed",
        }.get(exc.status_code, "httpError")
        message = exc.detail if isinstance(exc.detail, str) else "The request failed."
        return JSONResponse(
            status_code=exc.status_code,
            content=error_payload(
                code,
                message,
                request_id=getattr(request.state, "request_id", None),
            ),
            headers=exc.headers,
        )

    @app.exception_handler(ApiError)
    async def api_error_handler(request: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=error_payload(
                exc.code,
                exc.message,
                details=exc.details,
                request_id=getattr(request.state, "request_id", None),
            ),
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        details = exc.errors()
        for detail in details:
            detail.pop("ctx", None)
            # Validation inputs can contain passwords or push credentials. The
            # field location and error type are sufficient for clients.
            detail.pop("input", None)
        return JSONResponse(
            status_code=422,
            content=error_payload(
                "validationError",
                "The request is invalid.",
                details=details,
                request_id=getattr(request.state, "request_id", None),
            ),
        )

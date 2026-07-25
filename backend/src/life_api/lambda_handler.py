import os

from mangum import Mangum

from .main import app

handler = Mangum(
    app,
    lifespan="off",
    api_gateway_base_path=os.getenv("API_GATEWAY_BASE_PATH", "/"),
)

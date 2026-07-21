# syntax=docker/dockerfile:1.7
FROM dart:stable AS engine-build
WORKDIR /source
COPY packages/game_engine packages/game_engine
COPY tools/game_cli tools/game_cli
RUN mkdir -p /out && cd tools/game_cli && dart pub get && \
    dart compile exe bin/game_cli.dart -o /out/life-engine

FROM public.ecr.aws/lambda/python:3.12
COPY backend/pyproject.toml backend/README.md /build/
COPY backend/src /build/src
RUN python -m pip install --no-cache-dir /build && rm -rf /build
COPY --from=engine-build /out/life-engine /opt/life/bin/life-engine
ENV ENGINE_EXECUTABLE=/opt/life/bin/life-engine
CMD ["life_api.lambda_handler.handler"]

SHELL := /bin/bash
PYTHON ?= python3.12

.PHONY: bootstrap format analyze test test-engine test-ai test-app test-brand-icons test-backend brand-icons run-app run-backend build-web docker-backend

bootstrap:
	cd packages/game_engine && dart pub get
	cd packages/game_ai && dart pub get
	cd tools/game_cli && dart pub get
	cd apps/game_app && flutter pub get
	$(PYTHON) -m venv .venv
	.venv/bin/python -m pip install --upgrade pip
	.venv/bin/python -m pip install -e 'backend[dev]'
	.venv/bin/python -m pip install -r apps/game_app/tool/requirements-brand-icons.txt

format:
	dart format packages/game_engine packages/game_ai tools/game_cli apps/game_app
	.venv/bin/ruff format backend apps/game_app/tool

analyze:
	cd packages/game_engine && dart analyze --fatal-infos
	cd packages/game_ai && dart analyze --fatal-infos
	cd tools/game_cli && dart analyze --fatal-infos
	cd apps/game_app && flutter analyze --fatal-infos
	.venv/bin/ruff check backend apps/game_app/tool
	cd backend && ../.venv/bin/mypy src
	.venv/bin/python apps/game_app/tool/generate_brand_icons.py --check

test: test-engine test-ai test-backend test-app test-brand-icons

test-engine:
	cd packages/game_engine && dart test
	cd tools/game_cli && dart test

test-ai:
	cd packages/game_ai && dart test

test-app:
	cd apps/game_app && flutter test

test-brand-icons:
	.venv/bin/python apps/game_app/tool/generate_brand_icons.py --check

brand-icons:
	.venv/bin/python apps/game_app/tool/generate_brand_icons.py

test-backend:
	.venv/bin/pytest backend/tests

run-app:
	cd apps/game_app && flutter run -d chrome --web-port=3000 --dart-define=API_BASE_URL=http://localhost:8080

run-backend:
	cd backend && ../.venv/bin/uvicorn life_api.main:app --reload --port 8080

build-web:
	cd apps/game_app && flutter build web --release --no-web-resources-cdn

docker-backend:
	docker build -f backend/Dockerfile -t life-api:local .

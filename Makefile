VENV ?= .venv
PYTHON ?= $(VENV)/bin/python
RUFF ?= $(VENV)/bin/ruff
FLUTTER ?= flutter
CFN_LINT ?= $(VENV)/bin/cfn-lint

.PHONY: setup check lint format contract test infra-check portal-test lambda-package catalog-seed api-local mobile-setup mobile-check

setup:
	python3 -m venv $(VENV)
	$(PYTHON) -m pip install -r requirements-dev.lock

check: lint contract test infra-check portal-test

lint:
	$(RUFF) check .
	$(RUFF) format --check .

format:
	$(RUFF) check --fix .
	$(RUFF) format .

contract:
	$(PYTHON) PDLC/M4/validar_openapi_runpass.py

test:
	PYTHONPATH=backend $(PYTHON) -m unittest discover -s backend/tests -v

portal-test:
	cd portal && node --test lib.test.js

infra-check:
	$(CFN_LINT) -t infra/identity.template.json infra/data.template.yaml infra/app.template.yaml infra/deploy-role.template.yaml infra/cost.template.yaml infra/portal.template.yaml -r sa-east-1

lambda-package:
	PYTHON=$(PYTHON) scripts/package-lambda.sh

catalog-seed:
	PYTHONPATH=backend $(PYTHON) -m runpass.seed_catalog

api-local:
	PYTHONPATH=backend $(PYTHON) -m runpass.local_api

mobile-setup:
	cd mobile && $(FLUTTER) pub get --enforce-lockfile

mobile-check:
	cd mobile && $(FLUTTER) analyze
	cd mobile && dart format --output=none --set-exit-if-changed lib test
	cd mobile && $(FLUTTER) test

.PHONY: check fmt fmt-check build test lint lint-test doc-check source-check tooling-test release e2e

check: fmt-check build test lint-test lint source-check doc-check tooling-test e2e

fmt:
	gleam format
	cd packages/lint && gleam format

fmt-check:
	gleam format --check
	cd packages/lint && gleam format --check

build:
	gleam build --warnings-as-errors

test:
	gleam test

lint-test:
	cd packages/lint && gleam test

lint:
	bash scripts/lint.sh

source-check:
	python3 scripts/check_source.py

doc-check:
	python3 scripts/doc_check.py

tooling-test:
	python3 scripts/test_gates.py

release:
	gleam export erlang-shipment

e2e: release
	python3 test/e2e.py
	python3 test/e2e_http.py

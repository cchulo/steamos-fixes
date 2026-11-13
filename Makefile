# SPDX-License-Identifier: GPL-2.0-only
.PHONY: check lint test test-shell test-python fmt

check: lint test

lint:
	./scripts/lint.sh

test: test-shell test-python

test-shell:
	./tests/run.sh

# Prefer the pytest launcher when present (Homebrew's python3 has no pytest
# module); fall back to the module form used by CI's python3-pytest package.
PYTEST := $(shell command -v pytest 2>/dev/null || echo python3 -m pytest)

test-python:
	@if ls tests/python/test_*.py >/dev/null 2>&1; then 20 20 12 61 79 80 81 701 33 98 100 204 250 395 398 399 400PYTEST) -q tests/python; else echo "no python tests"; fi

fmt:
	shfmt -w -i 4 -ci -bn $$(git ls-files '*.sh' '*.bash' 'cmd/*' 'lib/*' 'scripts/*' 2>/dev/null | grep -v '\.bats$$')

# SPDX-License-Identifier: GPL-2.0-only
.PHONY: check lint test fmt

check: lint test

lint:
	./scripts/lint.sh

test:
	./tests/run.sh

fmt:
	shfmt -w -i 4 -ci -bn $$(git ls-files '*.sh' '*.bash' 'cmd/*' 'lib/*' 'scripts/*' 2>/dev/null | grep -v '\.bats$$')

# Lance fixtures for the lance_fdw regression suites.  See README.md.
#
#   make gen      regenerate data/, expected/*.jsonl and manifest.json
#   make upload   sync data/ into the MinIO bucket from test/gate/env.sh
#   make test     run the fixture tests (generates data/ if it is missing)
#
# The host virtualenv holds pylance/pyarrow/pytest/minio; override PYTHON to
# point somewhere else.

PYTHON ?= $(CURDIR)/../../.venv/bin/python
GEN_FLAGS ?=
UPLOAD_FLAGS ?=
PYTEST_FLAGS ?= -q

.PHONY: all gen upload test clean

all: gen

gen:
	$(PYTHON) gen_fixtures.py $(GEN_FLAGS)

upload:
	$(PYTHON) upload_minio.py $(UPLOAD_FLAGS)

test:
	$(PYTHON) -m pytest $(CURDIR) $(PYTEST_FLAGS)

# Only removes generated datasets; manifest.json and expected/ are committed.
clean:
	rm -rf $(CURDIR)/data

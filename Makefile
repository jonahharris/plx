# plx - PGXS build
MODULE_big = plx
OBJS = src/plx_core.o src/plx_transpile.o src/plx_dialect_ruby.o src/plx_dialect_php.o

EXTENSION = plx
DATA = plx--1.0.sql

# Tests are driven by test/run_corpus.py (Ruby corpus) and test/sql/php_smoke.sql.

# Point at the source-built PG 18 (not any distro pg_config on PATH).
PG_CONFIG ?= /usr/local/pgsql/bin/pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

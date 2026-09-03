EXTENSION    = pg_grammar_guard
DATA         = pg_grammar_guard--0.1.0.sql
PG_CONFIG   ?= pg_config

# One installcheck, no dependencies -- the same lesson pg_promise_guard took
# from pg_recall_guard: an installcheck that fails because of something the
# user does not have trains the user to ignore it.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

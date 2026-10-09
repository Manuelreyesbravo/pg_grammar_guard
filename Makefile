EXTENSION    = pg_grammar_guard
# The upgrade script is installed alongside both versions: without it, a user
# of 0.1.0 would have to drop the extension and create it again, and that takes
# approved_grammars with it -- losing exactly the baselines the guard half
# exists to keep.
DATA         = pg_grammar_guard--0.1.0.sql \
               pg_grammar_guard--0.2.0.sql \
               pg_grammar_guard--0.3.0.sql \
               pg_grammar_guard--0.1.0--0.2.0.sql \
               pg_grammar_guard--0.4.0.sql \
               pg_grammar_guard--0.4.1.sql \
               pg_grammar_guard--0.2.0--0.3.0.sql \
               pg_grammar_guard--0.3.0--0.4.0.sql \
               pg_grammar_guard--0.4.0--0.4.1.sql \
               pg_grammar_guard--0.4.1--0.4.2.sql \
               pg_grammar_guard--0.4.2--0.4.3.sql \
               pg_grammar_guard--0.4.3--0.4.4.sql \
               pg_grammar_guard--0.4.4--0.4.5.sql \
               pg_grammar_guard--0.4.5--0.4.6.sql \
               pg_grammar_guard--0.4.6--0.4.7.sql \
               pg_grammar_guard--0.4.7--0.4.8.sql
PG_CONFIG   ?= pg_config

# One installcheck, no dependencies -- the same lesson pg_promise_guard took
# from pg_recall_guard: an installcheck that fails because of something the
# user does not have trains the user to ignore it.
REGRESS      = basic
REGRESS_OPTS = --inputdir=test --outputdir=test

# Can a temporary table of the session that evaluates hide a drifted catalog? It
# could, through pg_temp, until 0.4.5. Needs a second role, so it is not part of
# installcheck; run it against the throwaway cluster of test/cluster.sh.
.PHONY: check-pgtemp
check-pgtemp:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/pg_temp.sh

# The findings of the external audit of 0.4.5, each against its control.
.PHONY: check-audit
check-audit:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/audit.sh

# Every suite in SUITES, in a throwaway cluster built from PG_CONFIG's binaries and
# stopped afterwards, whatever the suites answered. PostgreSQL 18 or later: the
# cluster loads this checkout through extension_control_path. CI runs exactly
# this on 18 and 19.
SUITES = check-pgtemp check-audit
.PHONY: check-suites
check-suites:
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh init
	@PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh start
	@st=0; for s in $(SUITES); do echo "== $$s"; \
	    $(MAKE) --no-print-directory $$s PG_CONFIG=$(PG_CONFIG) || st=1; done; \
	 PG_CONFIG=$(PG_CONFIG) bash ./test/cluster.sh stop; exit $$st

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

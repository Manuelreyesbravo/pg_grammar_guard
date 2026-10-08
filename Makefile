EXTENSION    = pg_grammar_guard
# El script de upgrade se instala junto a las dos versiones: sin el, un usuario
# de 0.1.0 tendria que borrar la extension y volver a crearla, y eso se lleva
# por delante approved_grammars -- o sea perderia justo los baselines que la
# mitad guard existe para conservar.
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
               pg_grammar_guard--0.4.4--0.4.5.sql
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

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

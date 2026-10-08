#!/usr/bin/env bash
# Can the session that EVALUATES a grammar hide that the catalog drifted?
#
# catalog_columns(), catalog_tables() and catalog_enum() read pg_attribute,
# pg_class and pg_enum without a schema under search_path = pg_catalog. pg_temp
# is not named, and PostgreSQL searches an unnamed pg_temp FIRST for tables: a
# temporary pg_attribute -- a copy of the real one minus the new column -- makes
# the live catalog read as the approved one.
#
# Against oneself that is nothing. It matters when the evaluation runs in
# SOMEONE ELSE's session with the owner's rights: a SECURITY DEFINER function of
# the owner that runs the assertion watch() declared -- which is what
# pg_agent_gate does inside an agent's commit. An agent allowed DDL keeps such a
# copy (CREATE TEMP TABLE ... AS is DDL), adds a column, and the assertion that
# should have caught the drift says `holds`.
#
# BOTH HALVES: without the temporary table the drift reads broken (the instrument
# can say red), and with it too.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/pg_temp.sh

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5494}
BASE=grammar_guard_test_pg_temp
OTHER=grammar_guard_test_pg_temp_other
failures=0

for what in "database:$BASE" "role:$OTHER"; do
    kind=${what%%:*}; name=${what#*:}
    q="select 1 from pg_database where datname = '$name'"
    [ "$kind" = role ] && q="select 1 from pg_roles where rolname = '$name'"
    if [ "$($PSQL -X -d postgres -tAc "$q")" = 1 ]; then
        echo "a $kind named $name already exists: not dropping what this script did not create" >&2
        exit 2
    fi
done
trap '$PSQL -X -d postgres -qc "drop database if exists $BASE" -c "drop role if exists $OTHER" >/dev/null 2>&1 || true' EXIT
$PSQL -X -d postgres -qc "create database $BASE" -c "create role $OTHER login"

$PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 -v other="$OTHER" >/dev/null <<'SQL'
CREATE EXTENSION pg_grammar_guard CASCADE;
CREATE SCHEMA app;
CREATE TABLE app.orders (id int, total numeric);
-- The approved grammar: the columns of app.orders as they are now.
SELECT grammar_guard.watch('orders',
    $$select to_jsonb(grammar_guard.catalog_columns('app.orders'::regclass))$$);
-- The drift: a column nobody approved.
ALTER TABLE app.orders ADD COLUMN secret text;
-- The pattern of pg_agent_gate: the owner runs the assertion on someone else's behalf.
CREATE FUNCTION public.evaluate(p text) RETURNS text LANGUAGE sql SECURITY DEFINER
    SET search_path = pg_catalog
    AS $$ SELECT (living_assertions.run(p)).state $$;
REVOKE ALL ON FUNCTION public.evaluate(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.evaluate(text) TO :"other";
-- The agent reaches its own schema, as it would. (The first version of this file did not grant
-- it: the temporary table was never created and the check passed against 0.4.4 for that reason.)
GRANT USAGE ON SCHEMA app TO :"other";
SQL

check() {
    local what="$1" expected="$2" got="$3"
    if [[ "$got" == *"$expected"* ]]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      ${got//$'\n'/ }"
        failures=$((failures + 1))
    fi
}

check "without a temporary table, the unapproved column reads as drift" "broken" \
    "$(PGUSER=$OTHER $PSQL -X -d "$BASE" -tAc "select evaluate('grammar:orders')" 2>&1 || true)"

# THE CASE: the same session keeps a copy of pg_attribute without the new column.
check "a temporary pg_attribute in the evaluating session does NOT hide the drift" "broken" \
    "$(PGUSER=$OTHER $PSQL -X -d "$BASE" -tA \
        -c "create temp table pg_attribute as select attrelid, attname, attnum, attisdropped from pg_catalog.pg_attribute where not (attrelid = 'app.orders'::regclass and attname = 'secret')" \
        -c "select evaluate('grammar:orders')" 2>&1 || true)"

check "and the owner, in its own session, still sees the drift" "broken" \
    "$($PSQL -X -d "$BASE" -tAc "select grammar_guard.check_grammar('orders')" 2>&1 || true)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "a temporary table of whoever evaluates does not hide a drifted catalog"

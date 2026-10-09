#!/usr/bin/env bash
# The findings of the external audit of 0.4.5 that this repo closed, each against its
# control -- the proof that the instrument can answer the other way.
#
#   GG-01 every function searched grammar_guard BEFORE pg_catalog, and CREATE EXTENSION used
#         a grammar_guard schema someone else had created: its owner's to_json() or md5()
#         ran in place of pg_catalog's, as whoever called -- a superuser, measured.
#   GG-02 catalog_tables() returned schema.name unquoted, so "Clientes" resolved to clientes:
#         the grammar offered another table's columns, and drift in "Clientes" read holds.
#   GG-04 catalog_tables() was not ordered: churn in pg_class moved the fingerprint of a
#         watch with no schema change, a false broken.
#   GG-03 a watch() declared by one role ran with the rights of whoever ran check_grammar().
#         Closed by pg_living_assertions 0.5.8, where a check runs as the role that declared
#         it; this suite needs that version (LIVING_ASSERTIONS_DIR, see test/cluster.sh).
#
# Run against the throwaway cluster: test/cluster.sh init && test/cluster.sh start.

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5494}
DB=grammar_guard_test_audit
SQUAT=grammar_guard_test_audit_squat
TENANT=grammar_guard_test_audit_tenant
EVIL=grammar_guard_test_audit_evil
failures=0

for what in "database:$DB" "database:$SQUAT" "role:$TENANT" "role:$EVIL"; do
    kind=${what%%:*}; name=${what#*:}
    q="select 1 from pg_database where datname = '$name'"
    [ "$kind" = role ] && q="select 1 from pg_roles where rolname = '$name'"
    if [ "$($PSQL -X -d postgres -tAc "$q")" = 1 ]; then
        echo "a $kind named $name already exists: not dropping what this script did not create" >&2
        exit 2
    fi
done
cleanup() {
    $PSQL -X -d postgres -qc "drop database if exists $DB" -c "drop database if exists $SQUAT" \
        -c "drop role if exists $TENANT" -c "drop role if exists $EVIL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

q()  { $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }
qt() { PGUSER=$TENANT $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }

check() {
    local what="$1" expected="$2" got="$3"
    if [[ "$got" == *"$expected"* ]]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      $got"
        failures=$((failures + 1))
    fi
}

$PSQL -X -d postgres -qc "create database $DB" -c "create database $SQUAT" \
    -c "create role $TENANT login" -c "create role $EVIL login" -c "grant create on database $SQUAT to $EVIL"

echo "GG-01: a grammar_guard schema created by someone else is not taken over"
$PSQL -X -d "$SQUAT" -q -c "create extension pg_living_assertions" >/dev/null
PGUSER=$EVIL $PSQL -X -d "$SQUAT" -q -c "create schema grammar_guard" \
    -c "create function grammar_guard.to_json(text) returns json language sql as \$\$ select '\"squatted\"'::json \$\$" >/dev/null
check "control: the squatter owns the schema" "$EVIL" \
    "$($PSQL -X -d "$SQUAT" -tAc "select nspowner::regrole from pg_namespace where nspname = 'grammar_guard'")"
check "CREATE EXTENSION refuses a schema owned by a role that is not a superuser" "ERROR" \
    "$($PSQL -X -d "$SQUAT" -tAc "create extension pg_grammar_guard" 2>&1)"
check "control: in a database nobody prepared, it installs" "CREATE EXTENSION" \
    "$(q -c "create extension pg_grammar_guard cascade")"
check "every function of the extension searches pg_catalog first" "functions_with_pg_catalog_first=all" \
    "$(q -c "select 'functions_with_pg_catalog_first=' || case when bool_and(array_to_string(proconfig, ',') like 'search_path=pg_catalog%') then 'all' else 'not all' end from pg_proc where pronamespace = 'grammar_guard'::regnamespace")"

echo "GG-02: a table with capitals is its own table"
q -q -c "create schema app4" -c "create table app4.clientes (id int, rut text)" \
     -c "create table app4.\"Clientes\" (\"ID\" int, \"Nombre\" text)" >/dev/null
check "control: both tables are listed" "2" \
    "$(q -c "select cardinality(grammar_guard.catalog_tables(array['app4']))")"
check "\"Clientes\" is offered its own columns" "Nombre" \
    "$(q -c "select grammar_guard.catalog_correlated(grammar_guard.catalog_tables(array['app4'])) -> 'dependents' -> 0 -> 'by_value'")"
q -q -c "select grammar_guard.watch('app4', \$\$select grammar_guard.catalog_correlated(grammar_guard.catalog_tables(array['app4']))\$\$)" \
     -c "alter table app4.\"Clientes\" add column \"Tarjeta\" text" >/dev/null
check "drift in \"Clientes\" reads broken" "broken" "$(q -c "select grammar_guard.check_grammar('app4')")"

echo "GG-04: the same tables are the same list, whatever pg_class's physical order"
q -q -c "create schema ord" -c "create table ord.zeta (a int)" -c "create table ord.mid (a int)" \
     -c "create table ord.beta (a int)" -c "create table ord.alpha (a int)" \
     -c "select grammar_guard.watch('ord', \$\$select to_jsonb(grammar_guard.catalog_tables(array['ord']))\$\$)" >/dev/null
before=$(q -c "select grammar_guard.catalog_tables(array['ord'])")
q -q -c "do \$\$ begin for i in 1..60 loop execute 'alter table ord.zeta set (fillfactor=' || (30 + i) || ')'; execute 'alter table ord.alpha set (fillfactor=' || (30 + i) || ')'; end loop; end \$\$" >/dev/null
check "control: the set of tables did not change" "same_set=true" \
    "$(q -c "select 'same_set=' || (array(select unnest('$before'::text[]) order by 1) = array(select unnest(grammar_guard.catalog_tables(array['ord'])) order by 1))")"
check "after pg_class churn, the watch still holds" "holds" "$(q -c "select grammar_guard.check_grammar('ord')")"

echo "GG-03: a watch runs as the role that declared it"
q -q -c "grant usage on schema grammar_guard, living_assertions to $TENANT" \
     -c "grant execute on all functions in schema living_assertions to $TENANT" \
     -c "grant select, insert on living_assertions.assertions, living_assertions.checks to $TENANT" >/dev/null
qt -q -c "select grammar_guard.watch('who', \$\$select jsonb_build_array(jsonb_build_object('name', 'who', 'kind', 'enum', 'required', true, 'values', jsonb_build_array(current_user::text)))\$\$)" >/dev/null
check "control: run by its author, the watch holds" "holds" "$(qt -c "select grammar_guard.check_grammar('who')")"
check "run by the superuser, it still runs as its author" "holds" "$(q -c "select grammar_guard.check_grammar('who')")"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the findings of the 0.4.5 audit are closed, each against its control"

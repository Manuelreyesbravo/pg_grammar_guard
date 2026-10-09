#!/usr/bin/env bash
# The findings of the external audit of 0.4.5 that this repo closed, each against its
# control -- the proof that the instrument can answer the other way.
#
#   GG-01 every function searched grammar_guard BEFORE pg_catalog, and CREATE EXTENSION used
#         a grammar_guard schema someone else had created: its owner's to_json() or md5()
#         ran in place of pg_catalog's, as whoever called -- a superuser, measured.
#   GG-02 catalog_tables() returned schema.name unquoted, so "Customers" resolved to customers:
#         the grammar offered another table's columns, and drift in "Customers" read holds.
#   GG-04 catalog_tables() was not ordered: churn in pg_class moved the fingerprint of a
#         watch with no schema change, a false broken.
#   GG-08..GG-18 (0.4.8): an empty correlated pivot, NULL grammars, fingerprint collisions, other
#         sessions' temporary tables, a spec that disappears, the watch's own path, unbounded
#         max_items, a quadratic enum build, a NULL dialect, duplicate and unnamed fields.
#   GG-03 a watch() declared by one role ran with the rights of whoever ran check_grammar().
#         Closed by pg_living_assertions 0.5.8, where a check runs as the role that declared
#         it; this suite needs that version (LIVING_ASSERTIONS_DIR, see test/cluster.sh).
#
# Run against the throwaway cluster: test/cluster.sh init && test/cluster.sh start.

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$ROOT/.testcluster} PGPORT=${PGPORT:-5494}
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
q -q -c "create schema app4" -c "create table app4.customers (id int, tax_id text)" \
     -c "create table app4.\"Customers\" (\"ID\" int, \"Name\" text)" >/dev/null
check "control: both tables are listed" "2" \
    "$(q -c "select cardinality(grammar_guard.catalog_tables(array['app4']))")"
check "\"Customers\" is offered its own columns" "Name" \
    "$(q -c "select grammar_guard.catalog_correlated(grammar_guard.catalog_tables(array['app4'])) -> 'dependents' -> 0 -> 'by_value'")"
q -q -c "select grammar_guard.watch('app4', \$\$select grammar_guard.catalog_correlated(grammar_guard.catalog_tables(array['app4']))\$\$)" \
     -c "alter table app4.\"Customers\" add column \"Card\" text" >/dev/null
check "drift in \"Customers\" reads broken" "broken" "$(q -c "select grammar_guard.check_grammar('app4')")"

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

echo "GG-08: an empty correlated pivot is refused"
check "control: an empty plain enum is refused" "enum with no values" \
    "$(q -c "select grammar_guard.grammar_for('[{\"name\":\"t\",\"kind\":\"enum\",\"required\":true,\"values\":[]}]')")"
check "an empty correlated pivot is refused too" "enum with no values" \
    "$(q -c "select grammar_guard.grammar_for(jsonb_build_array(grammar_guard.catalog_correlated(array[]::text[])))")"

echo "GG-10: never a NULL grammar"
check "an enum value NULL is refused" "none NULL" \
    "$(q -c "select grammar_guard.grammar_for('[{\"name\":\"a\",\"kind\":\"enum\",\"required\":true,\"values\":[\"x\",null]}]')")"
check "a field without a name is refused" "non-empty name" \
    "$(q -c "select grammar_guard.grammar_for('[{\"kind\":\"string\",\"required\":true}]')")"
check "a NULL value in grammar_for_json is refused" "an enum value is NULL" \
    "$(q -c "select grammar_guard.grammar_for_json(array[row('a','enum',array['x',null],true)]::grammar_guard.grammar_field[])")"

echo "GG-11: different grammars, different fingerprints"
check "a separator inside a value does not collide" "differ=true" \
    "$(q -c "select 'differ=' || (grammar_guard.grammar_fingerprint(array[row('m','enum',array['a','b'],true)]::grammar_guard.grammar_field[]) <> grammar_guard.grammar_fingerprint(array[row('m','enum',array[E'a\u0002b'],true)]::grammar_guard.grammar_field[]))")"
check "a NULL element does not vanish" "differ=true" \
    "$(q -c "select 'differ=' || (grammar_guard.grammar_fingerprint(array[row('m','enum',array['a'],true)]::grammar_guard.grammar_field[]) <> grammar_guard.grammar_fingerprint(array[row('m','enum',array['a',null],true)]::grammar_guard.grammar_field[]))")"

echo "GG-12: another session's temporary table is not the catalog"
check "a temporary table of this session is not listed" "listed=false" \
    "$(q -c "create temp table scratch_secret_plan (x int)" -c "select 'listed=' || (array_to_string(grammar_guard.catalog_tables(null), ',') like '%scratch_secret_plan%')" | tail -1)"

echo "GG-14: the spec resolves with its author's path"
q -q -c "create schema app3" -c "create table app3.invoices (id int, amount numeric)" >/dev/null
check "an unqualified name resolves in the author's schema" "watched" \
    "$(q -c "set search_path = app3, public" -c "select 'watched' from grammar_guard.watch('inv', \$\$select to_jsonb(grammar_guard.catalog_columns('invoices'::regclass))\$\$)" | tail -1)"
q -q -c "set search_path = app3, public" -c "create temp table invoices (id int, amount numeric, ghost text)" \
     -c "select grammar_guard.watch('inv_decoy', \$\$select to_jsonb(grammar_guard.catalog_columns('invoices'::regclass))\$\$)" >/dev/null 2>&1
check "  ...and a temporary decoy in the approving session is not what was approved (checked from a session without it)" "holds" \
    "$(q -c "select grammar_guard.check_grammar('inv_decoy')")"

echo "GG-13: a spec that disappears is broken"
q -q -c "create schema app5" -c "create table app5.a (x int)" \
     -c "select grammar_guard.watch('app5', \$\$select jsonb_agg(c.relname order by c.relname) from pg_class c where c.relnamespace = 'app5'::regnamespace and c.relkind = 'r'\$\$)" >/dev/null
check "control: it holds" "holds" "$(q -c "select grammar_guard.check_grammar('app5')")"
check "with every table dropped, it is broken" "broken" "$(q -c "drop table app5.a" -c "select grammar_guard.check_grammar('app5')" | tail -1)"

echo "GG-15, GG-17, GG-18: bounds and validation"
check "max_items beyond 1000 is refused" "between 1 and 1000" \
    "$(q -c "select grammar_guard.grammar_for('[{\"name\":\"a\",\"kind\":\"array\",\"required\":true,\"max_items\":2147483647,\"items\":{\"kind\":\"enum\",\"values\":[\"x\"]}}]')")"
check "max_items that is not a whole number is a clear error" "whole numbers" \
    "$(q -c "select grammar_guard.grammar_for('[{\"name\":\"a\",\"kind\":\"array\",\"required\":true,\"max_items\":\"3.5\",\"items\":{\"kind\":\"enum\",\"values\":[\"x\"]}}]')")"
check "a NULL dialect is refused in grammar_for_json" "unknown dialect" \
    "$(q -c "select grammar_guard.grammar_for_json(array[row('a','enum',array['x'],true)]::grammar_guard.grammar_field[], null)")"
check "a NULL dialect is refused in grammar_for" "unknown dialect" \
    "$(q -c "select grammar_guard.grammar_for('[{\"name\":\"a\",\"kind\":\"string\",\"required\":true}]', null)")"
check "two fields with the same name are refused" "same name" \
    "$(q -c "select grammar_guard.grammar_for('[{\"name\":\"a\",\"kind\":\"string\",\"required\":true},{\"name\":\"a\",\"kind\":\"string\",\"required\":true}]')")"
check "a required that is not a boolean is refused" "true or false" \
    "$(q -c "select grammar_guard.grammar_for('[{\"name\":\"a\",\"kind\":\"string\",\"required\":\"maybe\"}]')")"

echo "GG-16: a large enum builds in linear time"
check "40,000 values within 3 seconds" "built" \
    "$(q -c "set statement_timeout = '3s'" -c "select 'built' where length(grammar_guard.grammar_for(jsonb_build_array(jsonb_build_object('name','a','kind','enum','required',true,'values',(select jsonb_agg('v' || g) from generate_series(1, 40000) g))))) > 0" | tail -1)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the findings of the 0.4.5 audit are closed, each against its control"

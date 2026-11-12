#!/usr/bin/env bash
# Two things the README states about the grammars, measured instead of quoted:
#
#   size   how many bytes a flat grammar (table enum + column enum) and a correlated one
#          (columns depend on the table) take, over a generated schema of TABLES tables,
#          each with id, created_at and EXTRA columns of its own;
#   gbnf   that the grammars parse under llama.cpp's GBNF parser and accept and refuse what
#          the README says: a column of another table is refused by the correlated grammar
#          and accepted by the flat one; a column that exists nowhere is refused by both;
#          the nested README spec refuses "drop".
#
# The gbnf part needs llama.cpp's test-gbnf-validator (GBNF_VALIDATOR=path); without it, it
# is skipped and says so. Runs against the server PGHOST/PGPORT point at, with
# pg_grammar_guard installed; creates the database grammar_guard_bench (refuses if it exists)
# and drops it at the end.
#
#   PGHOST=... PGPORT=... GBNF_VALIDATOR=.../test-gbnf-validator bash bench/grammar_check.sh
set -euo pipefail

TABLES=${TABLES:-81}
EXTRA=${EXTRA:-4}
PSQL=${PSQL:-psql}
DB=grammar_guard_bench
WORK=$(mktemp -d)
q() { $PSQL -X -v ON_ERROR_STOP=1 -tAq -d "$DB" "$@"; }

[ -z "$($PSQL -X -tA -d postgres -c "select 1 from pg_database where datname = '$DB'")" ] ||
    { echo "database $DB exists: not touching it" >&2; exit 2; }
cleanup() { $PSQL -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true
            rm -f "$WORK"/*; rmdir "$WORK"; }
trap cleanup EXIT
$PSQL -X -q -d postgres -c "create database $DB"
q -c "create extension pg_grammar_guard cascade" 2>/dev/null
q <<SQL
CREATE SCHEMA app;
DO \$\$
BEGIN
    FOR i IN 1..$TABLES LOOP
        EXECUTE format('CREATE TABLE app.%I (id int PRIMARY KEY, created_at timestamptz %s)',
                       'tab_' || lpad(i::text, 3, '0'),
                       (SELECT string_agg(format(', %I text', 'tab_' || lpad(i::text, 3, '0') || '_c' || k), '')
                          FROM generate_series(1, $EXTRA) k));
    END LOOP;
END
\$\$;
-- The README's own two tables, for its examples.
CREATE SCHEMA readme;
CREATE TABLE readme.customers (id int PRIMARY KEY, tax_id text, name text);
CREATE TABLE readme.invoices (id int PRIMARY KEY, customer_id int, amount numeric);
SQL

flat="grammar_guard.grammar_for_json(ARRAY[
    ROW('table', 'enum', grammar_guard.catalog_tables(ARRAY['app']), true),
    ROW('column', 'enum', ARRAY(SELECT DISTINCT c FROM unnest(grammar_guard.catalog_tables(ARRAY['app'])) t,
                                 unnest(grammar_guard.catalog_columns(t::regclass)) c ORDER BY c), true)
  ]::grammar_guard.grammar_field[], '%s')"
corr="grammar_guard.grammar_for(jsonb_build_array(
    grammar_guard.catalog_correlated(grammar_guard.catalog_tables(ARRAY['app']))), '%s')"

echo "server: $(q -c 'select version()')"
echo "pg_grammar_guard $(q -c "select extversion from pg_extension where extname = 'pg_grammar_guard'")"
echo "schema: $TABLES tables, $(q -c "select count(distinct attname) from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'app' and c.relkind = 'r' and a.attnum > 0") distinct column names, $(q -c "select count(*) from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'app' and c.relkind = 'r' and a.attnum > 0") (table, column) pairs"
printf 'size gbnf         flat %7s bytes   correlated %7s bytes\n' \
    "$(q -c "select octet_length($(printf "$flat" gbnf))")" \
    "$(q -c "select octet_length($(printf "$corr" gbnf))")"
# grammar_for (nested, correlated) emits gbnf only.
printf 'size json_schema  flat %7s bytes   correlated     n/a\n' \
    "$(q -c "select octet_length($(printf "$flat" json_schema))")"

V=${GBNF_VALIDATOR:-}
if [ -z "$V" ] || [ ! -x "$V" ]; then
    echo "gbnf: SKIPPED (set GBNF_VALIDATOR to llama.cpp's test-gbnf-validator)"; exit 0
fi
q -c "select $(printf "$flat" gbnf)" > "$WORK/flat.gbnf"
q -c "select $(printf "$corr" gbnf)" > "$WORK/corr.gbnf"
q -c "select grammar_guard.grammar_for_json(ARRAY[
    ROW('table',  'enum', grammar_guard.catalog_tables(ARRAY['readme']), true),
    ROW('column', 'enum', grammar_guard.catalog_columns('readme.customers'), true),
    ROW('limit',  'integer', NULL, false)]::grammar_guard.grammar_field[])" > "$WORK/quick.gbnf"
q -c "select grammar_guard.grammar_for('[
  {\"name\": \"action\",  \"kind\": \"enum\", \"values\": [\"select\",\"count\"], \"required\": true},
  {\"name\": \"columns\", \"kind\": \"array\", \"required\": true, \"max_items\": 3,
   \"items\": {\"kind\": \"enum\", \"values\": [\"id\",\"amount\"]}},
  {\"name\": \"filter\",  \"kind\": \"object\", \"required\": false, \"fields\": [
     {\"name\": \"column\", \"kind\": \"enum\", \"values\": [\"id\"], \"required\": true},
     {\"name\": \"op\",     \"kind\": \"enum\", \"values\": [\"=\",\"<\"], \"required\": true}]}
]'::jsonb)" > "$WORK/nested.gbnf"

pass=0; fail=0
expect() {  # expect GRAMMAR valid|invalid INPUT
    local g=$1 want=$2 input=$3 got
    printf '%s' "$input" > "$WORK/input"
    if "$V" "$WORK/$g.gbnf" "$WORK/input" 2>&1 | grep -q 'Input string is valid'; then got=valid
    else got=invalid; fi
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); r=ok; else fail=$((fail + 1)); r=FAIL; fi
    printf 'gbnf %-4s %-6s %-7s %s\n' "$r" "$g" "$want" "$input"
}
expect flat   valid   '{"table":"app.tab_001","column":"tab_001_c1"}'
expect corr   valid   '{"table":"app.tab_001","column":"tab_001_c1"}'
expect flat   valid   '{"table":"app.tab_001","column":"tab_002_c1"}'
expect corr   invalid '{"table":"app.tab_001","column":"tab_002_c1"}'
expect flat   invalid '{"table":"app.tab_001","column":"no_such_column"}'
expect corr   invalid '{"table":"app.tab_001","column":"no_such_column"}'
expect corr   invalid '{"table":"app.no_such_table","column":"id"}'
expect quick  valid   '{"table":"readme.customers","column":"tax_id","limit":10}'
expect quick  invalid '{"table":"readme.customers","column":"email"}'
expect nested valid   '{"action":"select","columns":["id","id","id"],"filter":{"column":"id","op":"="}}'
expect nested invalid '{"action":"drop","columns":["id"]}'
expect nested invalid '{"action":"select","columns":["id","id","id","id"]}'
echo "gbnf: $pass as expected, $fail not"
[ "$fail" -eq 0 ]

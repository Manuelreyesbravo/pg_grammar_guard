-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_grammar_guard 0.4.4 -> 0.4.5
--
-- A temporary table of the session that EVALUATES a grammar could hide that the catalog
-- drifted. catalog_columns(), catalog_tables() and catalog_enum() read pg_attribute, pg_class
-- and pg_enum without a schema under search_path = pg_catalog; every function here named
-- pg_catalog or grammar_guard and never pg_temp, and PostgreSQL searches an unnamed pg_temp
-- FIRST for tables. A temporary pg_attribute -- a copy of the real one minus a new column --
-- made the live catalog read as the approved one.
--
-- Against oneself that is nothing. It matters when the evaluation runs in someone else's
-- session with the owner's rights: a SECURITY DEFINER function of the owner that runs the
-- assertion watch() declared -- which is what pg_agent_gate does inside an agent's commit, and
-- an agent allowed DDL can keep such a copy (CREATE TEMP TABLE ... AS is DDL). Measured on
-- 0.4.4 (test/pg_temp.sh): a column nobody approved read as drift, `broken`, and `holds` once
-- the evaluating session kept that copy.
--
-- Every function now names pg_temp LAST, so a temporary table can never stand in for the
-- catalog. No table changes.

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.4.5'" to load this file. \quit

ALTER FUNCTION grammar_guard._correlacionado(jsonb,text,integer) SET search_path = grammar_guard, pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard._reglas(jsonb,text) SET search_path = grammar_guard, pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.catalog_columns(regclass) SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.catalog_correlated(text[],text,text) SET search_path = grammar_guard, pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.catalog_enum(regtype) SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.catalog_tables(text[]) SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.check_grammar(text) SET search_path = grammar_guard, pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.gbnf_literal(text) SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.grammar_fingerprint(grammar_guard.grammar_field[]) SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.grammar_fingerprint(jsonb) SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.grammar_for(jsonb,text) SET search_path = grammar_guard, pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.grammar_for_json(grammar_guard.grammar_field[],text) SET search_path = grammar_guard, pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.json_string_literal(text) SET search_path = grammar_guard, pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.rule_name(text,integer) SET search_path = pg_catalog, pg_temp;
ALTER FUNCTION grammar_guard.watch(text,text,text) SET search_path = grammar_guard, pg_catalog, pg_temp;

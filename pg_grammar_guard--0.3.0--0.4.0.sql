-- pg_grammar_guard 0.3.0 -> 0.4.0
--
-- watch() stops rebuilding the freeze-and-compare by hand and calls
-- living_assertions.declare_unchanged() instead.
--
-- NOTHING CHANGES FOR EXISTING ASSERTIONS. Grammars watched under 0.3.0 keep
-- their stored check_sql and keep answering the same thing: the generated check
-- is equivalent, not shared. Re-run watch() on them only if you want them on
-- the new one.
--
-- Why this exists: 0.3.0 moved the baseline, the approve and the drift out, and
-- then wrote by hand the three steps around them -- evaluate now, freeze,
-- generate a check that re-evaluates and compares. pg_plan_guard writes the
-- same three steps for plan advice. The duplication had moved up a level rather
-- than gone, and a measurement caught it: the saving from the 0.3.0 port came
-- out below what had been declared. The metric was not wrong; the port was not
-- finished.

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.4.0'" to load this file. \quit

DROP FUNCTION IF EXISTS watch(text, text, text);

CREATE FUNCTION watch(p_name text, p_spec_sql text, p_note text DEFAULT NULL)
RETURNS bigint
LANGUAGE sql
SET search_path = grammar_guard, pg_catalog
AS $$
    SELECT living_assertions.declare_unchanged(
        'grammar:' || p_name,
        coalesce(p_note || ' -- ', '') ||
        'the approved grammar still describes the live catalog',
        format('select grammar_guard.grammar_fingerprint((%s)::jsonb)', p_spec_sql));
$$;

COMMENT ON FUNCTION watch(text, text, text) IS
    'Approves the grammar the spec query produces right now, and registers it as '
    'a living assertion so it keeps being checked. Takes the QUERY, not the '
    'spec: a stored spec would be compared against itself forever.';

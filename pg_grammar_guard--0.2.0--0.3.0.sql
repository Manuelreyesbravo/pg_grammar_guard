-- pg_grammar_guard 0.2.0 -> 0.3.0
--
-- The guard half moves to pg_living_assertions.
--
-- WHAT CANNOT BE MIGRATED AUTOMATICALLY, AND WHY IT IS THE INTERESTING PART.
--
-- 0.2.0 stored a fingerprint and nothing else. The spec was supplied by the
-- CALLER on every check_grammar(name, fields) call, which means the baseline
-- alone does not say what it was a baseline OF: there is no way, from a stored
-- fingerprint, to rebuild the spec from the catalog and compare. So these rows
-- cannot become living assertions without a human naming the query again.
--
-- That is not a migration inconvenience -- it is the defect the move exposed.
-- A check that needs the caller to bring the world can be run against the wrong
-- world and will report no drift, cheerfully. The rows are therefore KEPT, in a
-- clearly renamed table, and the operator is told out loud. Dropping them
-- silently would destroy the only record of what somebody had approved.

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.3.0'" to load this file. \quit

DROP FUNCTION IF EXISTS approve(text, grammar_field[], text, text);
DROP FUNCTION IF EXISTS approve(text, jsonb, text, text);
DROP FUNCTION IF EXISTS check_grammar(text, grammar_field[]);
DROP FUNCTION IF EXISTS check_grammar(text, jsonb);
DROP TYPE IF EXISTS grammar_break;

ALTER TABLE approved_grammars RENAME TO baselines_from_0_2_0;

COMMENT ON TABLE baselines_from_0_2_0 IS
    'Baselines approved under 0.2.0. They cannot be re-checked: 0.2.0 stored '
    'the fingerprint but never the query that rebuilds the spec, so nothing '
    'here can be compared against the live catalog. Re-approve each one with '
    'grammar_guard.watch(name, spec_query), then drop this table.';

DO $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM baselines_from_0_2_0;
    IF n > 0 THEN
        -- A WARNING and not a silent success. An upgrade that quietly leaves
        -- you with nothing watching is exactly the failure this extension
        -- exists to talk about: the mechanism ran, and what records it lies.
        RAISE WARNING '% grammar baseline(s) are no longer being checked', n
            USING HINT = 'They are in grammar_guard.baselines_from_0_2_0. Re-approve '
                         'each with grammar_guard.watch(name, spec_query) -- 0.2.0 '
                         'never stored the query, so this cannot be done for you.';
    END IF;
END;
$$;

-- The new guard half. Identical to the definitions in 0.3.0: an upgrade that
-- installs a different function body than a fresh install is how two users on
-- the same version stop behaving the same way.
CREATE FUNCTION watch(p_name text, p_spec_sql text, p_note text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = grammar_guard, pg_catalog
AS $$
DECLARE
    fp   text;
    spec jsonb;
BEGIN
    EXECUTE 'select (' || p_spec_sql || ')::jsonb' INTO spec;
    IF spec IS NULL THEN
        RAISE EXCEPTION 'the spec query returned NULL'
            USING HINT = 'p_spec_sql must be a query returning one jsonb value.';
    END IF;
    fp := grammar_fingerprint(spec);

    RETURN living_assertions.declare(
        'grammar:' || p_name,
        coalesce(p_note || ' -- ', '') ||
        'the approved grammar still describes the live catalog',
        format($f$select grammar_guard.grammar_fingerprint((%s)::jsonb) = %L as holds,
                         'approved %s, catalog now gives ' ||
                         grammar_guard.grammar_fingerprint((%s)::jsonb) as detail$f$,
               p_spec_sql, fp, fp, p_spec_sql));
END;
$$;

CREATE FUNCTION check_grammar(p_name text)
RETURNS text
LANGUAGE sql
SET search_path = grammar_guard, pg_catalog
AS $$
    SELECT (living_assertions.run('grammar:' || p_name)).state;
$$;

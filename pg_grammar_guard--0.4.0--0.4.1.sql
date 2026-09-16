-- pg_grammar_guard 0.4.0 -> 0.4.1
--
-- No behaviour changes.  Both functions aggregated a `name` column into an
-- array while declaring text[], which only PostgreSQL 13 and later accept;
-- on 12 and earlier every call raised
--
--     ERROR:  return type mismatch in function declared to return text[]
--
-- Measured across PostgreSQL 10 through 19.  The cast makes the extension
-- work on every one of them.

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.4.1'" to load this file. \quit

CREATE OR REPLACE FUNCTION catalog_columns(p_table regclass)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT coalesce(array_agg(a.attname::text ORDER BY a.attnum), '{}')
      FROM pg_attribute a
     WHERE a.attrelid = p_table
       AND a.attnum > 0
       AND NOT a.attisdropped;
$$;

CREATE OR REPLACE FUNCTION catalog_enum(p_type regtype)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT coalesce(array_agg(e.enumlabel::text ORDER BY e.enumsortorder), '{}')
      FROM pg_enum e
     WHERE e.enumtypid = p_type;
$$;

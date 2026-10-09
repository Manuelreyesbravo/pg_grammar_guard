-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_grammar_guard 0.4.6 -> 0.4.7
--
-- From an external audit of 0.4.5, each finding measured on 0.4.6 first (test/audit.sh:
-- every tooth red there with its control green).
--
--   * GG-01: CREATE EXTENSION used a grammar_guard schema that already existed, whoever owned
--     it, and eight functions searched grammar_guard before pg_catalog. The schema's owner --
--     any role with CREATE on the database -- could define to_json(text) or md5(text) there
--     and have it run as whoever called, a superuser measured. Putting pg_catalog first is
--     not enough on its own: PostgreSQL picks the overload that matches best, whatever schema
--     it is in, so a to_json(text) beats pg_catalog.to_json(anyelement) from any position.
--     The install now refuses a schema owned by a role that is neither the installer nor a
--     superuser, and every function searches pg_catalog first.
--   * GG-02: catalog_tables() returned schema.name unquoted, so "Customers" was read back as
--     customers: the grammar offered another table's columns, and drift in "Customers" read
--     holds. Names are quoted as identifiers now (format('%I.%I')); a lower-case name comes
--     out exactly as before, so no existing fingerprint of such tables changes.
--   * GG-04: catalog_tables() was not ordered: `ORDER BY 1` inside an aggregate orders by the
--     constant 1, so the list came out in pg_class's physical order, and churn of pg_class or a
--     dump and restore changed the fingerprint of a watch with no schema change -- a false
--     broken. It is ordered by schema and name now. A watch approved over catalog_tables() may
--     read broken once after this upgrade, if the order it was approved with was not that one:
--     re-approve it (watch() again under a new name, or living_assertions.declare with
--     supersedes). This script names the watches that call catalog_tables().
--   * GG-03: a watch ran with the rights of whoever ran check_grammar(). Closed by
--     pg_living_assertions 0.5.8, where a check runs as the role that declared it; this
--     version requires it.

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.4.7'" to load this file. \quit

DO $$
DECLARE
    owner_name name;
    owner_super boolean;
BEGIN
    SELECT r.rolname, r.rolsuper INTO owner_name, owner_super
      FROM pg_catalog.pg_namespace n JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
     WHERE n.nspname = 'grammar_guard';
    IF owner_name IS DISTINCT FROM current_user AND NOT owner_super THEN
        RAISE EXCEPTION 'pg_grammar_guard: schema grammar_guard is owned by %, not by the installer', owner_name
            USING DETAIL = 'Its owner can create functions there that this extension would call, with the rights of whoever calls it.',
                  HINT   = 'Drop that schema, or have a superuser own it, before installing.';
    END IF;
END $$;

DO $$
DECLARE
    f regprocedure;
BEGIN
    FOR f IN SELECT p.oid::regprocedure FROM pg_catalog.pg_proc p
              WHERE p.pronamespace = 'grammar_guard'::regnamespace
                AND pg_catalog.array_to_string(p.proconfig, ',') LIKE 'search_path=grammar_guard%'
    LOOP
        EXECUTE pg_catalog.format('ALTER FUNCTION %s SET search_path = pg_catalog, grammar_guard, pg_temp', f);
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION grammar_guard.catalog_tables(p_schemas text[] DEFAULT NULL::text[])
RETURNS text[]
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    -- Quoted as identifiers (0.4.7): "Clientes" unquoted reads back as clientes, another
    -- table. Ordered by schema and name (0.4.7): `ORDER BY 1` in an aggregate orders by the
    -- constant 1, and the physical order of pg_class moved the fingerprint on its own.
    SELECT coalesce(array_agg(format('%I.%I', n.nspname, c.relname) ORDER BY n.nspname, c.relname), '{}')
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND n.nspname <> ALL (ARRAY['pg_catalog', 'information_schema'])
       AND n.nspname NOT LIKE 'pg\_toast%'
       AND (p_schemas IS NULL OR n.nspname = ANY (p_schemas));
$$;

DO $$
DECLARE
    names text;
BEGIN
    SELECT string_agg(a.name, ', ' ORDER BY a.name) INTO names
      FROM living_assertions.assertions a
     WHERE a.retired_at IS NULL AND a.name LIKE 'grammar:%' AND a.check_sql LIKE '%catalog_tables%';
    IF names IS NOT NULL THEN
        RAISE WARNING 'pg_grammar_guard: these watches call catalog_tables(), whose order is now fixed: %', names
            USING DETAIL = 'One approved with the old, physical order reads broken once; the schema did not change.',
                  HINT   = 'Run check_grammar() on each; re-approve the ones that read broken.';
    END IF;
END $$;

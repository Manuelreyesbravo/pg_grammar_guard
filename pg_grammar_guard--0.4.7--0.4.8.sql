-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_grammar_guard 0.4.7 -> 0.4.8
--
-- The Medium and Low findings of the external audit of 0.4.5 left open, each measured on 0.4.7 first
-- (test/audit.sh: every tooth red there with its control green).
--
--   * GG-08: a correlated pivot with no values compiled to `root ::=`, a grammar that matches only "".
--   * GG-10: a NULL value, a field without a name, or a NULL pivot made the grammar NULL -- no
--     grammar at all, which a client reads as "unconstrained". Refused, and the result is never NULL.
--   * GG-11: grammar_fingerprint(grammar_field[]) concatenated with separators a value could contain
--     and dropped NULLs: two different grammars shared a fingerprint. It hashes the canonical JSON
--     now, like the jsonb variant. A fingerprint stored from it changes once.
--   * GG-12: catalog_tables() listed other sessions' temporary tables, so any role with TEMP made a
--     whole-database watch read broken while its session lasted.
--   * GG-13: a spec that came out NULL read unknown. With pg_living_assertions 0.5.9, which this
--     version requires, a fingerprinted value that disappears is broken.
--   * GG-14: watch() ran the spec under its own path, so an unqualified name in it ignored the
--     author's path and could only resolve in pg_temp. watch() keeps no path of its own now: the
--     author's is recorded, and applied with pg_temp last.
--   * GG-15: max_items had no ceiling (2147483647 was a bound in name only); it is 1000, and a value
--     that is not a whole number is a clear error.
--   * GG-16: an enum of 40,000 values took 10 s, one concatenation per value.
--   * GG-17: a NULL dialect went through `NULL <> 'gbnf'`.
--   * GG-18: duplicate field names, an empty name, a non-boolean `required` and non-string enum
--     values are refused.

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.4.8'" to load this file. \quit

CREATE OR REPLACE FUNCTION grammar_guard._reglas(p_campo jsonb, p_id text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'grammar_guard', 'pg_temp'
AS $function$
DECLARE
    kind   text := p_campo ->> 'kind';
    nombre text := coalesce(p_campo ->> 'name', '?');
    salida text := '';
    alts   text := '';
    cuerpo text := '';
    v      text;
    sub    jsonb;
    rid    text;
    i      int := 0;
    n_req  int := 0;
    tope   int;
    minimo int;
    pivote int;
BEGIN
    IF kind IS NULL THEN
        RAISE EXCEPTION 'field %: no kind', nombre;
    END IF;

    -- enum: the reason this extension exists.
    IF kind = 'enum' THEN
        IF p_campo -> 'values' IS NULL
           OR jsonb_typeof(p_campo -> 'values') <> 'array'
           OR jsonb_array_length(p_campo -> 'values') = 0 THEN
            -- A rule that matches nothing makes the model emit nothing, and that
            -- looks exactly like a hung model. Refused instead.
            RAISE EXCEPTION 'field %: enum with no values', nombre
                USING HINT = 'The query that fills this enum returned no rows.';
        END IF;
        -- Every value a string (0.4.8): a NULL made the whole grammar NULL -- no grammar at all
        -- for a client that reads NULL as "unconstrained" -- and a number was coerced silently.
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_campo -> 'values') x WHERE jsonb_typeof(x) <> 'string') THEN
            RAISE EXCEPTION 'field %: enum values must be strings, and none NULL', nombre;
        END IF;
        -- One string_agg, not a concatenation per value (0.4.8): 40,000 values took 10 s.
        SELECT string_agg(json_string_literal(x), ' | ' ORDER BY o) INTO alts
          FROM jsonb_array_elements_text(p_campo -> 'values') WITH ORDINALITY AS t(x, o);
        RETURN p_id || ' ::= ' || alts || E'\n';
    END IF;

    -- array: at least one item, because an empty array is almost never what the
    -- caller means and allowing it costs a whole alternative in every branch.
    --
    -- AND ALWAYS BOUNDED. An unbounded `( ... )*` is a loop waiting to happen:
    -- measured against a local 35B, an array of enum produced
    -- ["id","id","id", ...] forty-one times until it ran out of budget. That is
    -- the worst failure mode a grammar can have, because it does not fail --
    -- every token is legal, and a model stuck in it looks exactly like a model
    -- working. Same reason an empty enum is refused a few lines above.
    IF kind = 'array' THEN
        sub := p_campo -> 'items';
        IF sub IS NULL THEN
            RAISE EXCEPTION 'field %: array without items', nombre
                USING HINT = 'Give items a kind, e.g. {"kind": "enum", "values": [...]}.';
        END IF;
        -- Default 32, and the number is measured rather than chosen: over 721
        -- real array arguments the 95th percentile was 9 items and the largest
        -- was 84. 16 -- the first default written here -- would have cut that
        -- one silently, and a cap that truncates legitimate work is how a
        -- feature gets worked around instead of used.
        --
        -- A cap still has to EXIST, and that trade is deliberate: without one
        -- the model can loop forever emitting legal tokens, and truncating is
        -- far less bad than never stopping -- a truncated array is still valid,
        -- closed JSON that the caller can see is short.
        IF (p_campo ->> 'max_items') !~ '^[0-9]+$' OR (p_campo ->> 'min_items') !~ '^[0-9]+$' THEN
            RAISE EXCEPTION 'field %: max_items and min_items must be whole numbers', nombre;
        END IF;
        tope := coalesce((p_campo ->> 'max_items')::int, 32);
        -- A ceiling (0.4.8): max_items reached 2147483647, a bound in name only.
        IF tope < 1 OR tope > 1000 THEN
            RAISE EXCEPTION 'field %: max_items must be between 1 and 1000', nombre;
        END IF;
        -- min_items exists because the measurement found real arrays of length
        -- ZERO. The first version required at least one element, which would
        -- have made a legitimate empty list unreachable -- the same failure as
        -- the cap, in the other direction.
        minimo := coalesce((p_campo ->> 'min_items')::int, 1);
        IF minimo < 0 OR minimo > tope THEN
            RAISE EXCEPTION 'field %: min_items must be between 0 and max_items', nombre;
        END IF;
        rid := p_id || '-i';
        IF minimo = 0 THEN
            salida := p_id || ' ::= "[" ws ( ' || rid
                   || ' (ws "," ws ' || rid || '){0,' || (tope - 1)::text || '} ws )? "]"' || E'\n';
        ELSE
            salida := p_id || ' ::= "[" ws ' || rid
                   || ' (ws "," ws ' || rid || '){' || (minimo - 1)::text || ','
                   || (tope - 1)::text || '} ws "]"' || E'\n';
        END IF;
        RETURN salida || _reglas(sub, rid);
    END IF;

    -- object: the same shape as the root, one level down. Written once and
    -- reused by recursion, so the comma rules cannot drift between levels.
    IF kind = 'object' THEN
        IF p_campo -> 'fields' IS NULL OR jsonb_array_length(p_campo -> 'fields') = 0 THEN
            RAISE EXCEPTION 'field %: object with no fields', nombre;
        END IF;
        -- Every subfield named, once, with a boolean `required` (0.4.8): a duplicate name made an
        -- object with the key twice, which a JSON parser reads as the last one; a missing name
        -- made the whole grammar NULL.
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_campo -> 'fields') f
                    WHERE jsonb_typeof(f -> 'name') IS DISTINCT FROM 'string' OR f ->> 'name' = '') THEN
            RAISE EXCEPTION 'field %: every subfield needs a non-empty name', nombre;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_campo -> 'fields') f
                    GROUP BY f ->> 'name' HAVING count(*) > 1) THEN
            RAISE EXCEPTION 'field %: two subfields with the same name', nombre;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_campo -> 'fields') f
                    WHERE f ? 'required' AND jsonb_typeof(f -> 'required') <> 'boolean') THEN
            RAISE EXCEPTION 'field %: required must be true or false', nombre;
        END IF;

        -- CORRELATION. A field may carry `dependents`: other fields whose legal
        -- values depend on the value chosen for this one. Without it a grammar
        -- happily permits {"table":"facturas","column":"nombre"} where `nombre`
        -- belongs to another table -- well formed and impossible, which is the
        -- exact thing this extension exists to make unreachable.
        --
        -- Compiled as one root alternative per pivot value, so the dependent's
        -- rule is chosen by the token the model already emitted. Measured on a
        -- real 81-relation catalog: 10.9 KB flat, 22.2 KB correlated -- linear
        -- in (pivot, dependent) pairs, not the product.
        FOR i IN 0 .. jsonb_array_length(p_campo -> 'fields') - 1 LOOP
            IF (p_campo -> 'fields' -> i) ? 'dependents' THEN
                IF pivote IS NOT NULL THEN
                    -- Two pivots would need one alternative per COMBINATION, and
                    -- that is the exponential blowup people expect from this and
                    -- do not get. Refused rather than silently emitted.
                    RAISE EXCEPTION 'field %: two correlated fields in one object', nombre
                        USING HINT = 'Only one field per object may carry dependents.';
                END IF;
                pivote := i;
            END IF;
        END LOOP;

        IF pivote IS NOT NULL THEN
            RETURN _correlacionado(p_campo, p_id, pivote);
        END IF;
        FOR i IN 0 .. jsonb_array_length(p_campo -> 'fields') - 1 LOOP
            IF coalesce(((p_campo -> 'fields' -> i) ->> 'required')::boolean, false) THEN
                n_req := n_req + 1;
            END IF;
        END LOOP;
        IF n_req = 0 THEN
            RAISE EXCEPTION 'field %: every subfield is optional', nombre
                USING HINT = 'GBNF needs one required field to anchor the commas.';
        END IF;

        cuerpo := '"{" ws';
        -- Required first, then optional: fixed key order is what keeps comma
        -- placement decidable, and it is documented rather than hidden.
        FOR i IN 0 .. jsonb_array_length(p_campo -> 'fields') - 1 LOOP
            sub := p_campo -> 'fields' -> i;
            CONTINUE WHEN NOT coalesce((sub ->> 'required')::boolean, false);
            rid := p_id || '-' || i::text;
            IF cuerpo <> '"{" ws' THEN cuerpo := cuerpo || ' "," ws'; END IF;
            cuerpo := cuerpo || ' ' || gbnf_literal(to_json(sub ->> 'name')::text)
                   || ' ws ":" ws ' || rid || ' ws';
            salida := salida || _reglas(sub, rid);
        END LOOP;
        FOR i IN 0 .. jsonb_array_length(p_campo -> 'fields') - 1 LOOP
            sub := p_campo -> 'fields' -> i;
            CONTINUE WHEN coalesce((sub ->> 'required')::boolean, false);
            rid := p_id || '-' || i::text;
            cuerpo := cuerpo || ' ( "," ws ' || gbnf_literal(to_json(sub ->> 'name')::text)
                   || ' ws ":" ws ' || rid || ' ws )?';
            salida := salida || _reglas(sub, rid);
        END LOOP;
        RETURN p_id || ' ::= ' || cuerpo || ' "}"' || E'\n' || salida;
    END IF;

    IF kind IN ('string', 'integer', 'number', 'boolean') THEN
        RETURN p_id || ' ::= ' || kind || E'\n';
    END IF;

    RAISE EXCEPTION 'field %: unknown kind %', nombre, kind;
END;
$function$;

CREATE OR REPLACE FUNCTION grammar_guard._correlacionado(p_campo jsonb, p_id text, p_pivote integer)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'grammar_guard', 'pg_temp'
AS $function$
DECLARE
    campos  jsonb := p_campo -> 'fields';
    piv     jsonb := p_campo -> 'fields' -> p_pivote;
    deps    jsonb := (p_campo -> 'fields' -> p_pivote) -> 'dependents';
    nombres text[];
    ramas   text := '';
    reglas  text := '';
    cuerpo  text;
    dep     jsonb;
    valores text[];
    v       text;
    rid     text;
    i       int;
    j       int;
    k       int;
    primero boolean;
BEGIN
    IF NOT coalesce((piv ->> 'required')::boolean, false) THEN
        -- An optional pivot means the dependents have to be legal with AND
        -- without it, which doubles every branch for no real use case.
        RAISE EXCEPTION 'field %: a correlated field must be required', piv ->> 'name';
    END IF;
    -- The pivot's values, checked here too (0.4.8): only the plain enum path refused an empty
    -- list, and a pivot with none compiled to `root ::=` -- a grammar that matches only "".
    IF jsonb_typeof(piv -> 'values') IS DISTINCT FROM 'array' OR jsonb_array_length(piv -> 'values') = 0 THEN
        RAISE EXCEPTION 'field %: enum with no values', piv ->> 'name'
            USING HINT = 'The query that fills this enum returned no rows.';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(piv -> 'values') x WHERE jsonb_typeof(x) <> 'string') THEN
        RAISE EXCEPTION 'field %: enum values must be strings, and none NULL', piv ->> 'name';
    END IF;
    IF jsonb_typeof(deps) <> 'array' OR jsonb_array_length(deps) = 0 THEN
        RAISE EXCEPTION 'field %: dependents must be a non-empty array', piv ->> 'name';
    END IF;

    SELECT array_agg(d ->> 'name') INTO nombres FROM jsonb_array_elements(deps) d;

    FOR k IN 0 .. jsonb_array_length(piv -> 'values') - 1 LOOP
        v := piv -> 'values' ->> k;
        cuerpo := '"{" ws';
        primero := true;

        -- Required fields first, then optional: same order rule as an ordinary
        -- object, because the branches have to agree with each other and with
        -- what a reader of the flat case already expects.
        FOR i IN 0 .. jsonb_array_length(campos) - 1 LOOP
            CONTINUE WHEN NOT coalesce(((campos -> i) ->> 'required')::boolean, false);
            IF NOT primero THEN cuerpo := cuerpo || ' "," ws'; END IF;
            primero := false;
            cuerpo := cuerpo || ' ' || gbnf_literal(to_json((campos -> i) ->> 'name')::text)
                   || ' ws ":" ws ';
            IF ((campos -> i) ->> 'name') = ANY (nombres) THEN
                -- A dependent lives inside `dependents`, where its by_value is.
                -- Declaring it again in `fields` gives two places to keep in
                -- sync, and the first version of this silently emitted whichever
                -- one it met first.
                RAISE EXCEPTION 'field %: a dependent is declared inside dependents, '
                                'not again in fields', (campos -> i) ->> 'name';
            END IF;

            IF i = p_pivote THEN
                -- The pivot is a LITERAL in this branch, not a rule: that is
                -- what ties the dependent's choices to the token already emitted.
                cuerpo := cuerpo || json_string_literal(v) || ' ws';

                -- AND ITS DEPENDENTS COME RIGHT AFTER, always. They are not
                -- optional extras of the spec: emitting the pivot without them
                -- produces a grammar that is perfectly valid and MISSING A
                -- FIELD -- which is the worst thing this can do, because nothing
                -- errors and the caller gets a shorter object than they asked
                -- for. The first version did exactly that.
                FOR j IN 0 .. jsonb_array_length(deps) - 1 LOOP
                    dep := deps -> j;
                    IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(dep -> 'by_value' -> v, '[]'::jsonb)) x
                                WHERE jsonb_typeof(x) <> 'string') THEN
                        RAISE EXCEPTION 'field %: values must be strings, and none NULL', dep ->> 'name';
                    END IF;
                    SELECT array_agg(x) INTO valores
                      FROM jsonb_array_elements_text(coalesce(dep -> 'by_value' -> v, '[]'::jsonb)) x;
                    IF valores IS NULL OR cardinality(valores) = 0 THEN
                        -- A pivot value with no legal dependents makes that whole
                        -- branch unsatisfiable, and an unsatisfiable branch is
                        -- worse than a missing one: the model can enter it and
                        -- then have no legal token left.
                        RAISE EXCEPTION 'field %: no values for % = %',
                            dep ->> 'name', piv ->> 'name', v
                            USING HINT = 'Every value of the pivot needs at least one '
                                         'value for each dependent, or drop it from the pivot.';
                    END IF;
                    rid := p_id || '-v' || k::text || '-d' || j::text;
                    cuerpo := cuerpo || ' "," ws '
                           || gbnf_literal(to_json(dep ->> 'name')::text)
                           || ' ws ":" ws ' || rid || ' ws';
                    reglas := reglas || _reglas(
                        jsonb_build_object('kind', 'enum', 'name', dep ->> 'name',
                                           'values', to_jsonb(valores)), rid);
                END LOOP;
            ELSE
                -- Shared between branches, so its rules are emitted once.
                rid := p_id || '-' || i::text;
                cuerpo := cuerpo || rid || ' ws';
                IF k = 0 THEN reglas := reglas || _reglas(campos -> i, rid); END IF;
            END IF;
        END LOOP;

        FOR i IN 0 .. jsonb_array_length(campos) - 1 LOOP
            CONTINUE WHEN coalesce(((campos -> i) ->> 'required')::boolean, false);
            IF ((campos -> i) ->> 'name') = ANY (nombres) THEN
                RAISE EXCEPTION 'field %: a dependent is declared inside dependents, '
                                'not again in fields', (campos -> i) ->> 'name';
            END IF;
            rid := p_id || '-' || i::text;
            cuerpo := cuerpo || ' ( "," ws ' || gbnf_literal(to_json((campos -> i) ->> 'name')::text)
                   || ' ws ":" ws ' || rid || ' ws )?';
            IF k = 0 THEN reglas := reglas || _reglas(campos -> i, rid); END IF;
        END LOOP;

        IF ramas <> '' THEN ramas := ramas || ' | '; END IF;
        ramas := ramas || cuerpo || ' "}"';
    END LOOP;

    -- All alternatives on ONE line: in GBNF a rule ends at the newline, so
    -- splitting them to read better yields 'failed to parse grammar' with no
    -- line number. Measured against llama.cpp, not read.
    RETURN p_id || ' ::= ' || ramas || E'\n' || reglas;
END;
$function$;

CREATE OR REPLACE FUNCTION grammar_guard.grammar_for(p_fields jsonb, p_dialect text DEFAULT 'gbnf'::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'grammar_guard', 'pg_temp'
AS $function$
DECLARE
    reglas text;
BEGIN
    IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'array'
       OR jsonb_array_length(p_fields) = 0 THEN
        RAISE EXCEPTION 'no fields given'
            USING HINT = 'grammar_for takes a JSON array of field objects.';
    END IF;
    -- IS DISTINCT FROM (0.4.8): `NULL <> 'gbnf'` is NULL, and a NULL dialect went through.
    IF p_dialect IS DISTINCT FROM 'gbnf' THEN
        -- json_schema is not offered here on purpose: it cannot express "this
        -- string is one of these 400 column names" any better than 0.1.0 did,
        -- and pretending the nested case is covered by a validator that runs
        -- after generation would be promising more than it does.
        RAISE EXCEPTION 'unknown dialect: %', p_dialect
            USING HINT = 'grammar_for emits gbnf. For json_schema use the flat '
                         'grammar_for_json(grammar_field[], ''json_schema'').';
    END IF;

    reglas := _reglas(jsonb_build_object('kind', 'object', 'name', 'root',
                                         'fields', p_fields), 'root');
    -- Never a NULL grammar (0.4.8): a client that passes NULL to llama.cpp generates without
    -- any constraint, which is the failure this extension exists to prevent.
    IF reglas IS NULL THEN
        RAISE EXCEPTION 'the grammar came out NULL: a field is missing a name, a kind or a value';
    END IF;

    -- The scalar rules go in always. Working out which ones the tree actually
    -- reached would save a few hundred bytes and add a way to be wrong; an
    -- unused rule in GBNF costs nothing.
    RETURN reglas
        || E'string ::= "\\"" char* "\\""\n'
        || E'char ::= [^"\\\\\\x00-\\x1F] | "\\\\" (["\\\\/bfnrt] | "u" hex hex hex hex)\n'
        || E'hex ::= [0-9a-fA-F]\n'
        || E'integer ::= "-"? ("0" | [1-9] [0-9]*)\n'
        || E'number ::= integer ("." [0-9]+)? ([eE] [-+]? [0-9]+)?\n'
        || E'boolean ::= "true" | "false"\n'
        || E'ws ::= [ \\t\\n]*\n';
END;
$function$;

CREATE OR REPLACE FUNCTION grammar_guard.grammar_for_json(p_fields grammar_guard.grammar_field[], p_dialect text DEFAULT 'gbnf'::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'grammar_guard', 'pg_temp'
AS $function$
DECLARE
    f            grammar_field;
    i            int := 0;
    n_required   int := 0;
    rname        text;
    body         text := '';
    rules        text := '';
    alts         text;
    v            text;
    needs_scalar boolean := false;
    props        jsonb := '{}'::jsonb;
    req          jsonb := '[]'::jsonb;
BEGIN
    IF p_fields IS NULL OR cardinality(p_fields) = 0 THEN
        RAISE EXCEPTION 'no fields given'
            USING HINT = 'grammar_for_json needs at least one field to constrain.';
    END IF;

    IF p_dialect IS NULL OR p_dialect NOT IN ('gbnf', 'json_schema') THEN
        RAISE EXCEPTION 'unknown dialect: %', p_dialect
            USING HINT = 'Supported dialects are gbnf (llama.cpp) and json_schema.';
    END IF;

    FOREACH f IN ARRAY p_fields LOOP
        IF f.name IS NULL OR f.name = '' THEN
            RAISE EXCEPTION 'a field has no name';
        END IF;
        IF f.kind IS NULL OR f.kind NOT IN ('enum', 'string', 'integer', 'number', 'boolean') THEN
            RAISE EXCEPTION 'field %: unknown kind %', f.name, coalesce(f.kind, '<null>');
        END IF;
        IF f.kind = 'enum' AND (f.values IS NULL OR cardinality(f.values) = 0) THEN
            -- An enum with no values would emit a rule that matches nothing,
            -- and a grammar that matches nothing makes the model emit nothing.
            -- That looks exactly like a hung model, so it is refused here.
            RAISE EXCEPTION 'field %: enum with no values', f.name
                USING HINT = 'The query that fills this enum returned no rows. '
                             'An empty enum cannot be satisfied.';
        END IF;
        -- No NULL value (0.4.8): it made the gbnf grammar NULL, and the JSON Schema one allowed null.
        IF f.kind = 'enum' AND array_position(f.values, NULL) IS NOT NULL THEN
            RAISE EXCEPTION 'field %: an enum value is NULL', f.name;
        END IF;
        IF coalesce(f.required, false) THEN
            n_required := n_required + 1;
        END IF;
    END LOOP;
    IF (SELECT count(DISTINCT x.name) FROM unnest(p_fields) x) < cardinality(p_fields) THEN
        RAISE EXCEPTION 'two fields with the same name'
            USING HINT = 'A JSON object with a key twice is read as the last one.';
    END IF;

    -- ---------------------------------------------------------------- gbnf --
    IF p_dialect = 'gbnf' THEN
        IF n_required = 0 THEN
            -- With every field optional the object can be empty, and each field
            -- may or may not carry a leading comma. Emitting that correctly
            -- needs one alternative per subset. Refused instead of generating
            -- a grammar that is subtly wrong about commas.
            RAISE EXCEPTION 'every field is optional'
                USING HINT = 'GBNF needs at least one required field to anchor '
                             'the commas. Mark the field you always want as required.';
        END IF;

        body := '"{" ws';

        -- Required fields first, in the given order, then optional ones. The
        -- generated object therefore has a FIXED KEY ORDER. That is a real
        -- restriction and it is documented rather than hidden: it is what keeps
        -- the comma placement decidable.
        FOR i IN 1 .. cardinality(p_fields) LOOP
            f := p_fields[i];
            CONTINUE WHEN NOT coalesce(f.required, false);
            rname := rule_name(f.name, i);
            IF body <> '"{" ws' THEN
                body := body || ' "," ws';
            END IF;
            body := body || ' ' || gbnf_literal(to_json(f.name)::text) || ' ws ":" ws ' || rname || ' ws';
        END LOOP;

        FOR i IN 1 .. cardinality(p_fields) LOOP
            f := p_fields[i];
            CONTINUE WHEN coalesce(f.required, false);
            rname := rule_name(f.name, i);
            body := body || ' ( "," ws ' || gbnf_literal(to_json(f.name)::text)
                         || ' ws ":" ws ' || rname || ' ws )?';
        END LOOP;

        body := body || ' "}"';

        FOR i IN 1 .. cardinality(p_fields) LOOP
            f := p_fields[i];
            rname := rule_name(f.name, i);
            IF f.kind = 'enum' THEN
                SELECT string_agg(json_string_literal(x), ' | ' ORDER BY o) INTO alts
                  FROM unnest(f.values) WITH ORDINALITY AS t(x, o);
                rules := rules || rname || ' ::= ' || alts || E'\n';
            ELSE
                needs_scalar := true;
                rules := rules || rname || ' ::= ' || f.kind || E'\n';
            END IF;
        END LOOP;

        rules := 'root ::= ' || body || E'\n' || rules;

        IF needs_scalar THEN
            rules := rules
                || E'string ::= "\\"" char* "\\""\n'
                || E'char ::= [^"\\\\\\x00-\\x1F] | "\\\\" (["\\\\/bfnrt] | "u" hex hex hex hex)\n'
                || E'hex ::= [0-9a-fA-F]\n'
                || E'integer ::= "-"? ("0" | [1-9] [0-9]*)\n'
                || E'number ::= integer ("." [0-9]+)? ([eE] [-+]? [0-9]+)?\n'
                || E'boolean ::= "true" | "false"\n';
        END IF;

        rules := rules || E'ws ::= [ \\t\\n]*\n';
        RETURN rules;
    END IF;

    -- --------------------------------------------------------- json_schema --
    -- Emitted for the engines that only take a schema. It carries the same
    -- live enums, so it is still worth more than a hand-written schema -- but
    -- it is enforced by a validator after the fact, not by the sampler, and
    -- that difference is stated in the README rather than glossed over.
    FOR i IN 1 .. cardinality(p_fields) LOOP
        f := p_fields[i];
        IF f.kind = 'enum' THEN
            props := props || jsonb_build_object(f.name,
                jsonb_build_object('type', 'string', 'enum', to_jsonb(f.values)));
        ELSIF f.kind = 'integer' THEN
            props := props || jsonb_build_object(f.name, jsonb_build_object('type', 'integer'));
        ELSIF f.kind = 'number' THEN
            props := props || jsonb_build_object(f.name, jsonb_build_object('type', 'number'));
        ELSIF f.kind = 'boolean' THEN
            props := props || jsonb_build_object(f.name, jsonb_build_object('type', 'boolean'));
        ELSE
            props := props || jsonb_build_object(f.name, jsonb_build_object('type', 'string'));
        END IF;
        IF coalesce(f.required, false) THEN
            req := req || to_jsonb(f.name);
        END IF;
    END LOOP;

    RETURN jsonb_pretty(jsonb_build_object(
        'type', 'object',
        'properties', props,
        'required', req,
        'additionalProperties', false));
END;
$function$;

CREATE OR REPLACE FUNCTION grammar_guard.grammar_fingerprint(p_fields grammar_guard.grammar_field[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
    -- Over the FIELDS, not over the generated text: two dialects of the same
    -- world must fingerprint the same, or approving one would look like drift
    -- in the other. Enum values are hashed in the order given, because order is
    -- part of what the catalog said.
    -- Over the canonical JSON of the array (0.4.8), like the jsonb variant: the separators of the
    -- concatenation it replaced could occur in a value, and NULLs vanished from it, so two different
    -- grammars shared a fingerprint. `required` NULL and false are the same, as before.
    SELECT md5(to_jsonb(ARRAY(SELECT ROW(f.name, f.kind, f.values, coalesce(f.required, false))
                                FROM unnest(p_fields) WITH ORDINALITY AS f(name, kind, values, required, ord)
                               ORDER BY f.ord))::text);
$function$;

CREATE OR REPLACE FUNCTION grammar_guard.catalog_tables(p_schemas text[] DEFAULT NULL::text[])
RETURNS text[]
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    -- Quoted as identifiers and ordered (0.4.7). No session's temporary schema (0.4.8): another
    -- session's temporary table is not part of the catalog a model writes against, and listing it
    -- let any role with TEMP make a whole-database watch read broken.
    SELECT coalesce(array_agg(format('%I.%I', n.nspname, c.relname) ORDER BY n.nspname, c.relname), '{}')
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND n.nspname <> ALL (ARRAY['pg_catalog', 'information_schema'])
       AND n.nspname NOT LIKE 'pg\_toast%'
       AND n.nspname NOT LIKE 'pg\_temp\_%'
       AND (p_schemas IS NULL OR n.nspname = ANY (p_schemas));
$$;

-- No path of its own (0.4.8): the spec is the author's SQL, so the author's path is the one
-- recorded -- and pg_living_assertions applies it with pg_temp last, at approval and at every check.
-- Everything this body calls is qualified, so the caller's path decides nothing here.
CREATE OR REPLACE FUNCTION grammar_guard.watch(p_name text, p_spec_sql text, p_note text DEFAULT NULL::text)
RETURNS bigint
LANGUAGE sql
AS $$
    SELECT living_assertions.declare_unchanged(
        pg_catalog.concat('grammar:', p_name),
        pg_catalog.concat(CASE WHEN p_note IS NULL THEN '' ELSE pg_catalog.concat(p_note, ' -- ') END,
                          'the approved grammar still describes the live catalog'),
        pg_catalog.format('select grammar_guard.grammar_fingerprint((%s)::jsonb)', p_spec_sql));
$$;
ALTER FUNCTION grammar_guard.watch(text, text, text) RESET search_path;

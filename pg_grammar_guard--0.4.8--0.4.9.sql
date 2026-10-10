-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_grammar_guard 0.4.8 -> 0.4.9
--
-- No behavior change: the names inside function bodies are English. The grammars this version
-- generates are byte-identical to 0.4.8's.
--
--   * The internal _reglas(jsonb, text) is _rules(jsonb, text), and _correlacionado(jsonb, text,
--     integer) is _correlated(jsonb, text, integer). The old ones are dropped: they were internal,
--     and keeping them would leave two copies of the compiler to keep in step.
--   * Their parameters and local variables are English, and so are the comments in their bodies.
--   * grammar_for() calls _rules() instead of _reglas(); nothing else calls either.
--   * Settings are those of 0.4.8: same volatility, same search_path, no SECURITY DEFINER, and
--     the default privileges (no GRANT or REVOKE was ever issued on these functions).

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.4.9'" to load this file. \quit

CREATE FUNCTION grammar_guard._rules(p_field jsonb, p_id text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'grammar_guard', 'pg_temp'
AS $function$
DECLARE
    kind       text := p_field ->> 'kind';
    field_name text := coalesce(p_field ->> 'name', '?');
    rules      text := '';
    alts       text := '';
    body       text := '';
    v          text;
    sub        jsonb;
    rid        text;
    i          int := 0;
    n_req      int := 0;
    item_max   int;
    item_min   int;
    pivot      int;
BEGIN
    IF kind IS NULL THEN
        RAISE EXCEPTION 'field %: no kind', field_name;
    END IF;

    -- enum: the reason this extension exists.
    IF kind = 'enum' THEN
        IF p_field -> 'values' IS NULL
           OR jsonb_typeof(p_field -> 'values') <> 'array'
           OR jsonb_array_length(p_field -> 'values') = 0 THEN
            -- A rule that matches nothing makes the model emit nothing, and that
            -- looks exactly like a hung model. Refused instead.
            RAISE EXCEPTION 'field %: enum with no values', field_name
                USING HINT = 'The query that fills this enum returned no rows.';
        END IF;
        -- Every value a string (0.4.8): a NULL made the whole grammar NULL -- no grammar at all
        -- for a client that reads NULL as "unconstrained" -- and a number was coerced silently.
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_field -> 'values') x WHERE jsonb_typeof(x) <> 'string') THEN
            RAISE EXCEPTION 'field %: enum values must be strings, and none NULL', field_name;
        END IF;
        -- One string_agg, not a concatenation per value (0.4.8): 40,000 values took 10 s.
        SELECT string_agg(json_string_literal(x), ' | ' ORDER BY o) INTO alts
          FROM jsonb_array_elements_text(p_field -> 'values') WITH ORDINALITY AS t(x, o);
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
        sub := p_field -> 'items';
        IF sub IS NULL THEN
            RAISE EXCEPTION 'field %: array without items', field_name
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
        IF (p_field ->> 'max_items') !~ '^[0-9]+$' OR (p_field ->> 'min_items') !~ '^[0-9]+$' THEN
            RAISE EXCEPTION 'field %: max_items and min_items must be whole numbers', field_name;
        END IF;
        item_max := coalesce((p_field ->> 'max_items')::int, 32);
        -- A ceiling (0.4.8): max_items reached 2147483647, a bound in name only.
        IF item_max < 1 OR item_max > 1000 THEN
            RAISE EXCEPTION 'field %: max_items must be between 1 and 1000', field_name;
        END IF;
        -- min_items exists because the measurement found real arrays of length
        -- ZERO. The first version required at least one element, which would
        -- have made a legitimate empty list unreachable -- the same failure as
        -- the cap, in the other direction.
        item_min := coalesce((p_field ->> 'min_items')::int, 1);
        IF item_min < 0 OR item_min > item_max THEN
            RAISE EXCEPTION 'field %: min_items must be between 0 and max_items', field_name;
        END IF;
        rid := p_id || '-i';
        IF item_min = 0 THEN
            rules := p_id || ' ::= "[" ws ( ' || rid
                  || ' (ws "," ws ' || rid || '){0,' || (item_max - 1)::text || '} ws )? "]"' || E'\n';
        ELSE
            rules := p_id || ' ::= "[" ws ' || rid
                  || ' (ws "," ws ' || rid || '){' || (item_min - 1)::text || ','
                  || (item_max - 1)::text || '} ws "]"' || E'\n';
        END IF;
        RETURN rules || _rules(sub, rid);
    END IF;

    -- object: the same shape as the root, one level down. Written once and
    -- reused by recursion, so the comma rules cannot drift between levels.
    IF kind = 'object' THEN
        IF p_field -> 'fields' IS NULL OR jsonb_array_length(p_field -> 'fields') = 0 THEN
            RAISE EXCEPTION 'field %: object with no fields', field_name;
        END IF;
        -- Every subfield named, once, with a boolean `required` (0.4.8): a duplicate name made an
        -- object with the key twice, which a JSON parser reads as the last one; a missing name
        -- made the whole grammar NULL.
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_field -> 'fields') f
                    WHERE jsonb_typeof(f -> 'name') IS DISTINCT FROM 'string' OR f ->> 'name' = '') THEN
            RAISE EXCEPTION 'field %: every subfield needs a non-empty name', field_name;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_field -> 'fields') f
                    GROUP BY f ->> 'name' HAVING count(*) > 1) THEN
            RAISE EXCEPTION 'field %: two subfields with the same name', field_name;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_field -> 'fields') f
                    WHERE f ? 'required' AND jsonb_typeof(f -> 'required') <> 'boolean') THEN
            RAISE EXCEPTION 'field %: required must be true or false', field_name;
        END IF;

        -- CORRELATION. A field may carry `dependents`: other fields whose legal
        -- values depend on the value chosen for this one. Without it a grammar
        -- happily permits {"table":"invoices","column":"customer_name"} where
        -- `customer_name` belongs to another table -- well formed and impossible,
        -- which is the exact thing this extension exists to make unreachable.
        --
        -- Compiled as one root alternative per pivot value, so the dependent's
        -- rule is chosen by the token the model already emitted. Measured on a
        -- real 81-relation catalog: 10.9 KB flat, 22.2 KB correlated -- linear
        -- in (pivot, dependent) pairs, not the product.
        FOR i IN 0 .. jsonb_array_length(p_field -> 'fields') - 1 LOOP
            IF (p_field -> 'fields' -> i) ? 'dependents' THEN
                IF pivot IS NOT NULL THEN
                    -- Two pivots would need one alternative per COMBINATION, and
                    -- that is the exponential blowup people expect from this and
                    -- do not get. Refused rather than silently emitted.
                    RAISE EXCEPTION 'field %: two correlated fields in one object', field_name
                        USING HINT = 'Only one field per object may carry dependents.';
                END IF;
                pivot := i;
            END IF;
        END LOOP;

        IF pivot IS NOT NULL THEN
            RETURN _correlated(p_field, p_id, pivot);
        END IF;
        FOR i IN 0 .. jsonb_array_length(p_field -> 'fields') - 1 LOOP
            IF coalesce(((p_field -> 'fields' -> i) ->> 'required')::boolean, false) THEN
                n_req := n_req + 1;
            END IF;
        END LOOP;
        IF n_req = 0 THEN
            RAISE EXCEPTION 'field %: every subfield is optional', field_name
                USING HINT = 'GBNF needs one required field to anchor the commas.';
        END IF;

        body := '"{" ws';
        -- Required first, then optional: fixed key order is what keeps comma
        -- placement decidable, and it is documented rather than hidden.
        FOR i IN 0 .. jsonb_array_length(p_field -> 'fields') - 1 LOOP
            sub := p_field -> 'fields' -> i;
            CONTINUE WHEN NOT coalesce((sub ->> 'required')::boolean, false);
            rid := p_id || '-' || i::text;
            IF body <> '"{" ws' THEN body := body || ' "," ws'; END IF;
            body := body || ' ' || gbnf_literal(to_json(sub ->> 'name')::text)
                 || ' ws ":" ws ' || rid || ' ws';
            rules := rules || _rules(sub, rid);
        END LOOP;
        FOR i IN 0 .. jsonb_array_length(p_field -> 'fields') - 1 LOOP
            sub := p_field -> 'fields' -> i;
            CONTINUE WHEN coalesce((sub ->> 'required')::boolean, false);
            rid := p_id || '-' || i::text;
            body := body || ' ( "," ws ' || gbnf_literal(to_json(sub ->> 'name')::text)
                 || ' ws ":" ws ' || rid || ' ws )?';
            rules := rules || _rules(sub, rid);
        END LOOP;
        RETURN p_id || ' ::= ' || body || ' "}"' || E'\n' || rules;
    END IF;

    IF kind IN ('string', 'integer', 'number', 'boolean') THEN
        RETURN p_id || ' ::= ' || kind || E'\n';
    END IF;

    RAISE EXCEPTION 'field %: unknown kind %', field_name, kind;
END;
$function$;

CREATE FUNCTION grammar_guard._correlated(p_field jsonb, p_id text, p_pivot integer)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'grammar_guard', 'pg_temp'
AS $function$
DECLARE
    field_list      jsonb := p_field -> 'fields';
    pivot           jsonb := p_field -> 'fields' -> p_pivot;
    deps            jsonb := (p_field -> 'fields' -> p_pivot) -> 'dependents';
    dependent_names text[];
    branches        text := '';
    rules           text := '';
    body            text;
    dep             jsonb;
    dep_values      text[];
    v               text;
    rid             text;
    i               int;
    j               int;
    k               int;
    is_first        boolean;
BEGIN
    IF NOT coalesce((pivot ->> 'required')::boolean, false) THEN
        -- An optional pivot means the dependents have to be legal with AND
        -- without it, which doubles every branch for no real use case.
        RAISE EXCEPTION 'field %: a correlated field must be required', pivot ->> 'name';
    END IF;
    -- The pivot's values, checked here too (0.4.8): only the plain enum path refused an empty
    -- list, and a pivot with none compiled to `root ::=` -- a grammar that matches only "".
    IF jsonb_typeof(pivot -> 'values') IS DISTINCT FROM 'array' OR jsonb_array_length(pivot -> 'values') = 0 THEN
        RAISE EXCEPTION 'field %: enum with no values', pivot ->> 'name'
            USING HINT = 'The query that fills this enum returned no rows.';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(pivot -> 'values') x WHERE jsonb_typeof(x) <> 'string') THEN
        RAISE EXCEPTION 'field %: enum values must be strings, and none NULL', pivot ->> 'name';
    END IF;
    IF jsonb_typeof(deps) <> 'array' OR jsonb_array_length(deps) = 0 THEN
        RAISE EXCEPTION 'field %: dependents must be a non-empty array', pivot ->> 'name';
    END IF;

    SELECT array_agg(d ->> 'name') INTO dependent_names FROM jsonb_array_elements(deps) d;

    FOR k IN 0 .. jsonb_array_length(pivot -> 'values') - 1 LOOP
        v := pivot -> 'values' ->> k;
        body := '"{" ws';
        is_first := true;

        -- Required fields first, then optional: same order rule as an ordinary
        -- object, because the branches have to agree with each other and with
        -- what a reader of the flat case already expects.
        FOR i IN 0 .. jsonb_array_length(field_list) - 1 LOOP
            CONTINUE WHEN NOT coalesce(((field_list -> i) ->> 'required')::boolean, false);
            IF NOT is_first THEN body := body || ' "," ws'; END IF;
            is_first := false;
            body := body || ' ' || gbnf_literal(to_json((field_list -> i) ->> 'name')::text)
                 || ' ws ":" ws ';
            IF ((field_list -> i) ->> 'name') = ANY (dependent_names) THEN
                -- A dependent lives inside `dependents`, where its by_value is.
                -- Declaring it again in `fields` gives two places to keep in
                -- sync, and the first version of this silently emitted whichever
                -- one it met first.
                RAISE EXCEPTION 'field %: a dependent is declared inside dependents, '
                                'not again in fields', (field_list -> i) ->> 'name';
            END IF;

            IF i = p_pivot THEN
                -- The pivot is a LITERAL in this branch, not a rule: that is
                -- what ties the dependent's choices to the token already emitted.
                body := body || json_string_literal(v) || ' ws';

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
                    SELECT array_agg(x) INTO dep_values
                      FROM jsonb_array_elements_text(coalesce(dep -> 'by_value' -> v, '[]'::jsonb)) x;
                    IF dep_values IS NULL OR cardinality(dep_values) = 0 THEN
                        -- A pivot value with no legal dependents makes that whole
                        -- branch unsatisfiable, and an unsatisfiable branch is
                        -- worse than a missing one: the model can enter it and
                        -- then have no legal token left.
                        RAISE EXCEPTION 'field %: no values for % = %',
                            dep ->> 'name', pivot ->> 'name', v
                            USING HINT = 'Every value of the pivot needs at least one '
                                         'value for each dependent, or drop it from the pivot.';
                    END IF;
                    rid := p_id || '-v' || k::text || '-d' || j::text;
                    body := body || ' "," ws '
                         || gbnf_literal(to_json(dep ->> 'name')::text)
                         || ' ws ":" ws ' || rid || ' ws';
                    rules := rules || _rules(
                        jsonb_build_object('kind', 'enum', 'name', dep ->> 'name',
                                           'values', to_jsonb(dep_values)), rid);
                END LOOP;
            ELSE
                -- Shared between branches, so its rules are emitted once.
                rid := p_id || '-' || i::text;
                body := body || rid || ' ws';
                IF k = 0 THEN rules := rules || _rules(field_list -> i, rid); END IF;
            END IF;
        END LOOP;

        FOR i IN 0 .. jsonb_array_length(field_list) - 1 LOOP
            CONTINUE WHEN coalesce(((field_list -> i) ->> 'required')::boolean, false);
            IF ((field_list -> i) ->> 'name') = ANY (dependent_names) THEN
                RAISE EXCEPTION 'field %: a dependent is declared inside dependents, '
                                'not again in fields', (field_list -> i) ->> 'name';
            END IF;
            rid := p_id || '-' || i::text;
            body := body || ' ( "," ws ' || gbnf_literal(to_json((field_list -> i) ->> 'name')::text)
                 || ' ws ":" ws ' || rid || ' ws )?';
            IF k = 0 THEN rules := rules || _rules(field_list -> i, rid); END IF;
        END LOOP;

        IF branches <> '' THEN branches := branches || ' | '; END IF;
        branches := branches || body || ' "}"';
    END LOOP;

    -- All alternatives on ONE line: in GBNF a rule ends at the newline, so
    -- splitting them to read better yields 'failed to parse grammar' with no
    -- line number. Measured against llama.cpp, not read.
    RETURN p_id || ' ::= ' || branches || E'\n' || rules;
END;
$function$;

CREATE OR REPLACE FUNCTION grammar_guard.grammar_for(p_fields jsonb, p_dialect text DEFAULT 'gbnf'::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'grammar_guard', 'pg_temp'
AS $function$
DECLARE
    rules text;
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

    rules := _rules(jsonb_build_object('kind', 'object', 'name', 'root',
                                       'fields', p_fields), 'root');
    -- Never a NULL grammar (0.4.8): a client that passes NULL to llama.cpp generates without
    -- any constraint, which is the failure this extension exists to prevent.
    IF rules IS NULL THEN
        RAISE EXCEPTION 'the grammar came out NULL: a field is missing a name, a kind or a value';
    END IF;

    -- The scalar rules go in always. Working out which ones the tree actually
    -- reached would save a few hundred bytes and add a way to be wrong; an
    -- unused rule in GBNF costs nothing.
    RETURN rules
        || E'string ::= "\\"" char* "\\""\n'
        || E'char ::= [^"\\\\\\x00-\\x1F] | "\\\\" (["\\\\/bfnrt] | "u" hex hex hex hex)\n'
        || E'hex ::= [0-9a-fA-F]\n'
        || E'integer ::= "-"? ("0" | [1-9] [0-9]*)\n'
        || E'number ::= integer ("." [0-9]+)? ([eE] [-+]? [0-9]+)?\n'
        || E'boolean ::= "true" | "false"\n'
        || E'ws ::= [ \\t\\n]*\n';
END;
$function$;

DROP FUNCTION grammar_guard._correlacionado(jsonb, text, integer);
DROP FUNCTION grammar_guard._reglas(jsonb, text);

COMMENT ON FUNCTION grammar_guard._correlated(jsonb, text, integer) IS
    'Internal. Compiles a pivot field into one alternative per value, with each dependent restricted to what is legal for that value. This is what makes {"table":"invoices","column":"customer_name"} unreachable instead of merely wrong.';

COMMENT ON FUNCTION grammar_guard._rules(jsonb, text) IS
    'Internal. Recursive: an object compiles its subfields the same way the root compiles its fields, so the comma and ordering rules cannot drift between levels -- writing the nested case separately is how two levels of the same grammar start disagreeing.';

-- pg_grammar_guard 0.2.0
--
-- Compiles a token-level grammar from the live catalog, so a constrained model
-- cannot name a table, a column or a value that does not exist -- and tells you
-- when a grammar you approved stopped describing your database.
--
-- The failure this exists for: everyone believes structured output stops a
-- model from inventing things about their database. It does not. A JSON Schema
-- guarantees the JSON parses and that "column" is a string. It cannot guarantee
-- the string is a column that EXISTS, because a schema document is written once
-- and the catalog changes on every migration.
--
-- The distinction this extension is built on: a grammar constrains FORM. In the
-- general case form is not truth. But for identifiers form IS truth, because the
-- set of valid names is finite and only PostgreSQL knows it right now.
--
-- And the guard half: a grammar generated last month against a schema migrated
-- last week still constrains, still looks like it is protecting you, and what it
-- permits is no longer your database. It does not error. It quietly allows a
-- dropped column and quietly forbids a new one.
--
-- Every function sets its own search_path. Not style: this extension installs
-- into its own schema, so an unqualified reference would resolve through the
-- CALLER's search_path -- which fails at runtime for anyone who has not added
-- the schema, and, worse, lets a caller decide which "md5" the generator uses.

\echo Use "CREATE EXTENSION pg_grammar_guard" to load this file. \quit


-- ---------------------------------------------------------------------------
-- What a field is. This is the whole input language of the extension.
-- ---------------------------------------------------------------------------
CREATE TYPE grammar_field AS (
    name      text,     -- the JSON key
    kind      text,     -- enum | string | integer | number | boolean
    values    text[],   -- kind='enum': the permitted values, live from wherever
    required  boolean
);

COMMENT ON TYPE grammar_field IS
    'kind=enum is the point of this extension: the permitted values are a '
    'finite set the catalog knows today. Every other kind is an ordinary '
    'scalar and buys nothing a JSON Schema does not already give you.';


-- ---------------------------------------------------------------------------
-- Live sources. Thin on purpose: the value is that they are read at generation
-- time, not that they are clever.
-- ---------------------------------------------------------------------------
CREATE FUNCTION catalog_tables(p_schemas text[] DEFAULT NULL)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT coalesce(array_agg(n.nspname || '.' || c.relname ORDER BY 1), '{}')
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND n.nspname <> ALL (ARRAY['pg_catalog', 'information_schema'])
       AND n.nspname NOT LIKE 'pg\_toast%'
       AND (p_schemas IS NULL OR n.nspname = ANY (p_schemas));
$$;

COMMENT ON FUNCTION catalog_tables(text[]) IS
    'Schema-qualified relations the current role can see. Views and matviews '
    'are included: a model asked to read data has no reason to care which is '
    'which, and excluding them is how a legitimate answer becomes unreachable.';


CREATE FUNCTION catalog_columns(p_table regclass)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT coalesce(array_agg(a.attname ORDER BY a.attnum), '{}')
      FROM pg_attribute a
     WHERE a.attrelid = p_table
       AND a.attnum > 0
       AND NOT a.attisdropped;
$$;

COMMENT ON FUNCTION catalog_columns(regclass) IS
    'Ordered by attnum, not by name: a dropped-and-recreated column changes '
    'position, and that is a change the fingerprint should see.';


CREATE FUNCTION catalog_enum(p_type regtype)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT coalesce(array_agg(e.enumlabel ORDER BY e.enumsortorder), '{}')
      FROM pg_enum e
     WHERE e.enumtypid = p_type;
$$;


-- ---------------------------------------------------------------------------
-- Escaping. Two different jobs, and mixing them is how a grammar silently
-- starts permitting something else.
-- ---------------------------------------------------------------------------
CREATE FUNCTION gbnf_literal(p_value text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog
AS $$
    -- A GBNF literal is delimited by double quotes, so a backslash must be
    -- doubled BEFORE the quote is escaped -- the other order escapes the
    -- backslash that was just added.
    SELECT '"' || replace(replace(p_value, '\', '\\'), '"', '\"') || '"';
$$;

CREATE FUNCTION json_string_literal(p_value text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
SET search_path = grammar_guard, pg_catalog
AS $$
    -- The value must appear inside the generated text as a JSON string, and
    -- that JSON string is itself inside a GBNF literal. to_json does the first
    -- level correctly (including control characters); gbnf_literal the second.
    SELECT gbnf_literal(to_json(p_value)::text);
$$;

COMMENT ON FUNCTION json_string_literal(text) IS
    'Two levels of quoting, applied in this order. Doing it by hand with '
    'replace() is how a value containing a quote or a newline turns into a '
    'grammar that parses and permits the wrong language.';


CREATE FUNCTION rule_name(p_field text, p_ordinal int)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
    -- GBNF rule names allow only letters, digits and dashes. The ordinal is
    -- always appended so two fields that sanitise to the same name ("a.b" and
    -- "a-b") cannot collide into one rule -- a collision here would silently
    -- give one field the other's permitted values.
    SELECT 'f' || p_ordinal::text || '-' ||
           coalesce(nullif(regexp_replace(lower(p_field), '[^a-z0-9]+', '-', 'g'), ''), 'x');
$$;


-- ---------------------------------------------------------------------------
-- The generator.
-- ---------------------------------------------------------------------------
CREATE FUNCTION grammar_for_json(p_fields grammar_field[], p_dialect text DEFAULT 'gbnf')
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = grammar_guard, pg_catalog
AS $$
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

    IF p_dialect NOT IN ('gbnf', 'json_schema') THEN
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
        IF coalesce(f.required, false) THEN
            n_required := n_required + 1;
        END IF;
    END LOOP;

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
                alts := '';
                FOREACH v IN ARRAY f.values LOOP
                    IF alts <> '' THEN
                        alts := alts || ' | ';
                    END IF;
                    alts := alts || json_string_literal(v);
                END LOOP;
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
$$;

COMMENT ON FUNCTION grammar_for_json(grammar_field[], text) IS
    'Compiles the fields into a grammar. dialect=gbnf is enforced by the '
    'sampler, so an invalid value is unreachable rather than rejected after '
    'the fact. dialect=json_schema carries the same live enums for engines '
    'that cannot take a grammar. The gbnf object has a FIXED key order.';


-- ---------------------------------------------------------------------------
-- The guard half.
-- ---------------------------------------------------------------------------
CREATE FUNCTION grammar_fingerprint(p_fields grammar_field[])
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
    -- Over the FIELDS, not over the generated text: two dialects of the same
    -- world must fingerprint the same, or approving one would look like drift
    -- in the other. Enum values are hashed in the order given, because order is
    -- part of what the catalog said.
    SELECT md5(string_agg(
               f.name || E'\u0001' || f.kind || E'\u0001' ||
               coalesce(f.required, false)::text || E'\u0001' ||
               coalesce(array_to_string(f.values, E'\u0002'), ''),
               E'\u0003' ORDER BY f.ord))
      FROM unnest(p_fields) WITH ORDINALITY AS f(name, kind, values, required, ord);
$$;


CREATE TABLE approved_grammars (
    name          text PRIMARY KEY,
    fingerprint   text NOT NULL,
    dialect       text NOT NULL DEFAULT 'gbnf',
    field_count   int  NOT NULL,
    approved_at   timestamptz NOT NULL DEFAULT now(),
    approved_by   text NOT NULL DEFAULT current_user,
    note          text
);

SELECT pg_catalog.pg_extension_config_dump('approved_grammars', '');

COMMENT ON TABLE approved_grammars IS
    'What you decided was correct, and when. Dumped with pg_dump: a baseline '
    'that does not survive a restore is a baseline that quietly resets to '
    'whatever the schema happens to be on the new host.';


CREATE TYPE grammar_break AS (
    name         text,
    detail       text,
    severity     text,   -- drift | never_approved
    approved     text,
    current      text,
    approved_at  timestamptz
);


CREATE FUNCTION approve(p_name text, p_fields grammar_field[],
                        p_dialect text DEFAULT 'gbnf', p_note text DEFAULT NULL)
RETURNS text
LANGUAGE sql
SET search_path = grammar_guard, pg_catalog
AS $$
    INSERT INTO approved_grammars (name, fingerprint, dialect, field_count, note)
    VALUES (p_name, grammar_fingerprint(p_fields), p_dialect,
            cardinality(p_fields), p_note)
    ON CONFLICT (name) DO UPDATE
       SET fingerprint = excluded.fingerprint,
           dialect     = excluded.dialect,
           field_count = excluded.field_count,
           approved_at = now(),
           approved_by = current_user,
           note        = excluded.note
    RETURNING fingerprint;
$$;


CREATE FUNCTION check_grammar(p_name text, p_fields grammar_field[])
RETURNS SETOF grammar_break
LANGUAGE sql STABLE
SET search_path = grammar_guard, pg_catalog
AS $$
    SELECT p_name,
           CASE WHEN a.name IS NULL
                THEN 'this grammar was never approved, so nothing here can '
                     'tell you whether it still describes your database'
                ELSE 'the approved grammar no longer describes the current '
                     'catalog: what it permits is not what exists'
           END,
           CASE WHEN a.name IS NULL THEN 'never_approved' ELSE 'drift' END,
           a.fingerprint,
           grammar_fingerprint(p_fields),
           a.approved_at
      FROM (SELECT 1) _
      LEFT JOIN approved_grammars a ON a.name = p_name
     WHERE a.name IS NULL
        OR a.fingerprint IS DISTINCT FROM grammar_fingerprint(p_fields);
$$;

COMMENT ON FUNCTION check_grammar(text, grammar_field[]) IS
    'Empty result means the approved grammar still matches the world. '
    'never_approved is reported as its own severity and never as drift: a '
    'grammar nobody approved is not one that changed, and collapsing the two '
    'is how a monitor starts reporting something it cannot know.';



-- ---------------------------------------------------------------------------
-- One field, compiled to its own rule plus every rule underneath it. Returns
-- the rules; the caller already knows the name it asked for.
-- ---------------------------------------------------------------------------
CREATE FUNCTION _reglas(p_campo jsonb, p_id text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = grammar_guard, pg_catalog
AS $$
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
        FOR v IN SELECT jsonb_array_elements_text(p_campo -> 'values') LOOP
            IF alts <> '' THEN alts := alts || ' | '; END IF;
            alts := alts || json_string_literal(v);
        END LOOP;
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
        tope := coalesce((p_campo ->> 'max_items')::int, 32);
        IF tope < 1 THEN
            RAISE EXCEPTION 'field %: max_items must be >= 1', nombre;
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
$$;

COMMENT ON FUNCTION _reglas(jsonb, text) IS
    'Internal. Recursive: an object compiles its subfields the same way the root '
    'compiles its fields, so the comma and ordering rules cannot drift between '
    'levels -- writing the nested case separately is how two levels of the same '
    'grammar start disagreeing.';


-- ---------------------------------------------------------------------------
-- The public entry point for the recursive case.
-- ---------------------------------------------------------------------------
CREATE FUNCTION grammar_for(p_fields jsonb, p_dialect text DEFAULT 'gbnf')
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = grammar_guard, pg_catalog
AS $$
DECLARE
    reglas text;
BEGIN
    IF p_fields IS NULL OR jsonb_typeof(p_fields) <> 'array'
       OR jsonb_array_length(p_fields) = 0 THEN
        RAISE EXCEPTION 'no fields given'
            USING HINT = 'grammar_for takes a JSON array of field objects.';
    END IF;
    IF p_dialect <> 'gbnf' THEN
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
$$;

COMMENT ON FUNCTION grammar_for(jsonb, text) IS
    'Compiles a nested field spec into GBNF. A field is {name, kind, required} '
    'plus, for kind=enum, values; for kind=array, items; for kind=object, '
    'fields. Key order in the generated object is fixed: required fields in the '
    'order given, then optional ones.';


CREATE FUNCTION grammar_fingerprint(p_fields jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
    -- Over the canonical JSON of the spec. jsonb already normalises key order
    -- and whitespace, so two specs that describe the same world fingerprint the
    -- same even if they were written differently -- which is the property that
    -- makes approve() usable at all.
    SELECT md5(p_fields::text);
$$;

COMMENT ON FUNCTION grammar_fingerprint(jsonb) IS
    'The nested counterpart of grammar_fingerprint(grammar_field[]). The two do '
    'NOT agree with each other, and that is correct: approving a spec under one '
    'shape and checking it under the other is comparing two different things, so '
    'it should read as drift rather than as silence.';


CREATE FUNCTION approve(p_name text, p_fields jsonb,
                        p_dialect text DEFAULT 'gbnf', p_note text DEFAULT NULL)
RETURNS text
LANGUAGE sql
SET search_path = grammar_guard, pg_catalog
AS $$
    INSERT INTO approved_grammars (name, fingerprint, dialect, field_count, note)
    VALUES (p_name, grammar_fingerprint(p_fields), p_dialect,
            jsonb_array_length(p_fields), p_note)
    ON CONFLICT (name) DO UPDATE
       SET fingerprint = excluded.fingerprint,
           dialect     = excluded.dialect,
           field_count = excluded.field_count,
           approved_at = now(),
           approved_by = current_user,
           note        = excluded.note
    RETURNING fingerprint;
$$;


CREATE FUNCTION check_grammar(p_name text, p_fields jsonb)
RETURNS SETOF grammar_break
LANGUAGE sql STABLE
SET search_path = grammar_guard, pg_catalog
AS $$
    SELECT p_name,
           CASE WHEN a.name IS NULL
                THEN 'this grammar was never approved, so nothing here can '
                     'tell you whether it still describes your database'
                ELSE 'the approved grammar no longer describes the current '
                     'catalog: what it permits is not what exists'
           END,
           CASE WHEN a.name IS NULL THEN 'never_approved' ELSE 'drift' END,
           a.fingerprint,
           grammar_fingerprint(p_fields),
           a.approved_at
      FROM (SELECT 1) _
      LEFT JOIN approved_grammars a ON a.name = p_name
     WHERE a.name IS NULL
        OR a.fingerprint IS DISTINCT FROM grammar_fingerprint(p_fields);
$$;

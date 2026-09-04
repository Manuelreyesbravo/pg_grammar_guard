-- pg_grammar_guard 0.1.0 -> 0.2.0
--
-- Adds arrays and nesting. 0.1.0 could only describe a flat object of scalars,
-- which is not the shape of a real tool call: `paths: [...]` and
-- `filter: {column: ..., op: ...}` were both unreachable.
--
-- The composite type stays for the flat case, because it reads better there.
-- The recursive case takes JSONB, because a PostgreSQL composite type cannot
-- contain itself -- and a flat type pretending to describe a tree is how a
-- grammar starts silently ignoring the parts it cannot express.

\echo Use "ALTER EXTENSION pg_grammar_guard UPDATE TO '0.2.0'" to load this file. \quit


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

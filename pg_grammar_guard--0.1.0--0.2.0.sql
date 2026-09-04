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
$$;

-- ---------------------------------------------------------------------------
-- One alternative per value of the pivot field. Mutually recursive with
-- _reglas: the non-correlated fields compile exactly the same way they would
-- anywhere else, so a dependent object or array behaves identically inside a
-- correlated branch and outside it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION _correlacionado(p_campo jsonb, p_id text, p_pivote int)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = grammar_guard, pg_catalog
AS $$
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
$$;

COMMENT ON FUNCTION _correlacionado(jsonb, text, int) IS
    'Internal. Compiles a pivot field into one alternative per value, with each '
    'dependent restricted to what is legal for that value. This is what makes '
    '{"table":"facturas","column":"nombre"} unreachable instead of merely wrong.';


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


-- ---------------------------------------------------------------------------
-- The canonical correlation, built from the catalog so nobody has to type it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION catalog_correlated(p_tables text[],
                                   p_pivot text DEFAULT 'table',
                                   p_dependent text DEFAULT 'column')
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = grammar_guard, pg_catalog
AS $$
    -- Takes an explicit list of tables rather than a schema. Measured on a real
    -- 81-relation catalog the correlated grammar is 22.2 KB, so at ~200
    -- relations it lands near 55 KB -- which is a lot to hand a sampler on every
    -- request. Naming the tables the request could plausibly touch is the point,
    -- not a workaround: a grammar listing the whole database is the 45k-token
    -- tool schema all over again.
    SELECT jsonb_build_object(
        'name', p_pivot,
        'kind', 'enum',
        'required', true,
        'values', to_jsonb(p_tables),
        'dependents', jsonb_build_array(jsonb_build_object(
            'name', p_dependent,
            'kind', 'enum',
            'required', true,
            'by_value', (SELECT coalesce(jsonb_object_agg(t, cols), '{}'::jsonb)
                           FROM (SELECT t,
                                        to_jsonb(catalog_columns(t::regclass)) AS cols
                                   FROM unnest(p_tables) t) _
                          WHERE jsonb_array_length(cols) > 0))));
$$;

COMMENT ON FUNCTION catalog_correlated(text[], text, text) IS
    'Builds the pivot field for the canonical case: the legal columns depend on '
    'the table already chosen. Feed the result to grammar_for as one of its '
    'fields. A table whose columns are not visible to the current role is left '
    'out of by_value, and grammar_for then refuses that branch rather than '
    'emitting one the model can enter and get stuck in.';


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

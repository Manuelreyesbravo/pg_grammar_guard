-- Deterministic: no timestamps, no oids, no catalog-wide scans. The temporary
-- schema is created here so the catalog sources have something they own to read
-- -- reading the whole cluster would make the expected output depend on what
-- else happens to be installed.

CREATE EXTENSION pg_grammar_guard;
SET search_path = grammar_guard, public;

CREATE SCHEMA gg_test;
CREATE TABLE gg_test.clientes (id int, rut text, nombre text);
CREATE TABLE gg_test.facturas (id int, cliente_id int, monto numeric);
CREATE VIEW  gg_test.vigentes AS SELECT * FROM gg_test.facturas;
CREATE TYPE  gg_test.estado AS ENUM ('abierta', 'pagada', 'anulada');

-- ---------------------------------------------------------------- sources --
SELECT catalog_tables(ARRAY['gg_test']);
SELECT catalog_columns('gg_test.clientes');
SELECT catalog_enum('gg_test.estado');

-- A dropped column must disappear from the columns and therefore from the
-- grammar. This is the whole premise: the grammar tracks the catalog.
ALTER TABLE gg_test.clientes DROP COLUMN rut;
SELECT catalog_columns('gg_test.clientes');

-- ------------------------------------------------------------- generation --
SELECT grammar_for_json(ARRAY[
    ROW('table',  'enum', catalog_tables(ARRAY['gg_test']), true),
    ROW('column', 'enum', catalog_columns('gg_test.facturas'), true),
    ROW('limit',  'integer', NULL, false)
]::grammar_field[]);

-- Same fields, the other dialect.
SELECT grammar_for_json(ARRAY[
    ROW('table',  'enum', catalog_tables(ARRAY['gg_test']), true),
    ROW('limit',  'integer', NULL, false)
]::grammar_field[], 'json_schema');

-- ---------------------------------------------------------------- quoting --
-- A value carrying a quote, a backslash and a newline. Both quoting levels have
-- to survive: the JSON one and the GBNF one. Getting the order wrong here does
-- not raise an error, it produces a grammar that permits a different language.
SELECT grammar_for_json(ARRAY[
    ROW('v', 'enum', ARRAY['plain', 'has"quote', 'has\back', E'has\nnewline'], true)
]::grammar_field[]);

-- Two field names that sanitise to the same rule name. Without the ordinal they
-- would collide and one field would silently get the other's permitted values.
SELECT grammar_for_json(ARRAY[
    ROW('a.b', 'enum', ARRAY['x'], true),
    ROW('a-b', 'enum', ARRAY['y'], true)
]::grammar_field[]);

-- --------------------------------------------------------------- refusals --
-- Each of these is refused rather than compiled into something subtly wrong.
SELECT grammar_for_json(ARRAY[ROW('v', 'enum', '{}'::text[], true)]::grammar_field[]);
SELECT grammar_for_json(ARRAY[ROW('v', 'enum', ARRAY['x'], false)]::grammar_field[]);
SELECT grammar_for_json(ARRAY[ROW('v', 'colour', NULL, true)]::grammar_field[]);
SELECT grammar_for_json(ARRAY[ROW('v', 'enum', ARRAY['x'], true)]::grammar_field[], 'lark');
SELECT grammar_for_json('{}'::grammar_field[]);

-- ------------------------------------------------------------ fingerprint --
-- Over the fields, not over the emitted text: the two dialects of one world
-- must fingerprint the same, or approving one would read as drift in the other.
SELECT grammar_fingerprint(ARRAY[ROW('t', 'enum', ARRAY['a', 'b'], true)]::grammar_field[])
     = grammar_fingerprint(ARRAY[ROW('t', 'enum', ARRAY['a', 'b'], true)]::grammar_field[])
       AS stable;

-- Order of enum values is part of what the catalog said, so it changes it.
SELECT grammar_fingerprint(ARRAY[ROW('t', 'enum', ARRAY['a', 'b'], true)]::grammar_field[])
    <> grammar_fingerprint(ARRAY[ROW('t', 'enum', ARRAY['b', 'a'], true)]::grammar_field[])
       AS order_matters;

-- ------------------------------------------------------------------ guard --
-- Never approved is its own severity, not drift.
SELECT name, severity FROM check_grammar('answer',
    ARRAY[ROW('table', 'enum', catalog_tables(ARRAY['gg_test']), true)]::grammar_field[]);

SELECT approve('answer',
    ARRAY[ROW('table', 'enum', catalog_tables(ARRAY['gg_test']), true)]::grammar_field[],
    'gbnf', 'test') IS NOT NULL AS approved;

-- Approved and unchanged: silent. This is the half a monitor gets wrong.
SELECT count(*) AS breaks FROM check_grammar('answer',
    ARRAY[ROW('table', 'enum', catalog_tables(ARRAY['gg_test']), true)]::grammar_field[]);

-- The world moves.
CREATE TABLE gg_test.pagos (id int);

SELECT name, severity, (approved <> current) AS fingerprint_moved
  FROM check_grammar('answer',
    ARRAY[ROW('table', 'enum', catalog_tables(ARRAY['gg_test']), true)]::grammar_field[]);

-- And re-approving makes it silent again, which is what makes the check usable
-- twice: a monitor that cannot be acknowledged gets ignored.
SELECT approve('answer',
    ARRAY[ROW('table', 'enum', catalog_tables(ARRAY['gg_test']), true)]::grammar_field[])
    IS NOT NULL AS reapproved;

SELECT count(*) AS breaks FROM check_grammar('answer',
    ARRAY[ROW('table', 'enum', catalog_tables(ARRAY['gg_test']), true)]::grammar_field[]);

-- ------------------------------------------------- arrays and nesting (0.2) --
-- The shape of a real tool call, which 0.1.0 could not express at all.
SELECT grammar_for('[
    {"name": "action", "kind": "enum", "values": ["select", "count"], "required": true},
    {"name": "columns", "kind": "array", "required": true,
     "items": {"kind": "enum", "values": ["id", "monto"]}},
    {"name": "filter", "kind": "object", "required": false, "fields": [
        {"name": "column", "kind": "enum", "values": ["id"], "required": true},
        {"name": "op", "kind": "enum", "values": ["=", "<"], "required": true},
        {"name": "value", "kind": "integer", "required": false}
    ]}
]'::jsonb);

-- An array OF objects: two levels of recursion, which is where a hand-written
-- nested case would have started disagreeing with the root.
SELECT grammar_for('[
    {"name": "edits", "kind": "array", "required": true, "items": {
        "kind": "object", "fields": [
            {"name": "path", "kind": "enum", "values": ["a.ts"], "required": true},
            {"name": "text", "kind": "string", "required": true}
        ]}}
]'::jsonb);

-- REGRESSION: arrays are bounded. An unbounded ( ... )* is a loop waiting to
-- happen -- measured against a local 35B, an array of enum emitted
-- ["id","id","id", ...] forty-one times until it ran out of budget, every token
-- legal. A model stuck in that looks exactly like a model working, which is the
-- worst thing a grammar can do. Default 16, overridable per field.
SELECT grammar_for('[{"name": "xs", "kind": "array", "required": true, "max_items": 3,
                     "items": {"kind": "enum", "values": ["a"]}}]'::jsonb);
SELECT grammar_for('[{"name": "xs", "kind": "array", "required": true,
                     "items": {"kind": "enum", "values": ["a"]}}]'::jsonb);
SELECT grammar_for('[{"name": "xs", "kind": "array", "required": true, "max_items": 0,
                     "items": {"kind": "enum", "values": ["a"]}}]'::jsonb);

-- min_items exists because the measurement found real arrays of length ZERO.
-- Requiring one element would make a legitimate empty list unreachable -- the
-- same failure as an unbounded array, in the other direction.
SELECT grammar_for('[{"name": "xs", "kind": "array", "required": true, "min_items": 0,
                     "max_items": 2, "items": {"kind": "enum", "values": ["a"]}}]'::jsonb);
SELECT grammar_for('[{"name": "xs", "kind": "array", "required": true, "min_items": 2,
                     "max_items": 4, "items": {"kind": "enum", "values": ["a"]}}]'::jsonb);
SELECT grammar_for('[{"name": "xs", "kind": "array", "required": true, "min_items": 5,
                     "max_items": 2, "items": {"kind": "enum", "values": ["a"]}}]'::jsonb);

-- --------------------------------------------------------- correlation --
-- The canonical case, and the reason this extension exists: without it a
-- grammar permits {"table":"facturas","column":"nombre"} where nombre belongs
-- to clientes -- well formed and impossible.
SELECT grammar_for(jsonb_build_array(
    catalog_correlated(ARRAY['gg_test.clientes', 'gg_test.facturas'])));

-- Built straight from the catalog, so it tracks a dropped column like the rest.
SELECT (catalog_correlated(ARRAY['gg_test.clientes'])
        -> 'dependents' -> 0 -> 'by_value' -> 'gg_test.clientes') AS columnas_de_clientes;

-- With another required field alongside: it is shared between branches and its
-- rule is emitted once, not once per pivot value.
SELECT grammar_for(jsonb_build_array(
    catalog_correlated(ARRAY['gg_test.clientes', 'gg_test.facturas']),
    jsonb_build_object('name','limit','kind','integer','required',true)));

-- Refusals specific to correlation.
-- El pivote no puede ser opcional.
SELECT grammar_for('[{"name":"t","kind":"enum","values":["a"],"required":false,
    "dependents":[{"name":"c","kind":"enum","required":true,"by_value":{"a":["x"]}}]}]'::jsonb);

-- Un valor del pivote sin columnas legales haria esa rama insatisfacible: el
-- modelo puede entrar y quedarse sin ningun token legal.
SELECT grammar_for('[{"name":"t","kind":"enum","values":["a","b"],"required":true,
    "dependents":[{"name":"c","kind":"enum","required":true,"by_value":{"a":["x"]}}]}]'::jsonb);

-- Dos pivotes pediria una alternativa por COMBINACION -- la explosion que la
-- gente espera de esto y que no ocurre, justamente porque se rechaza.
SELECT grammar_for('[{"name":"t","kind":"enum","values":["a"],"required":true,
     "dependents":[{"name":"c","kind":"enum","required":true,"by_value":{"a":["x"]}}]},
    {"name":"u","kind":"enum","values":["a"],"required":true,
     "dependents":[{"name":"d","kind":"enum","required":true,"by_value":{"a":["y"]}}]}]'::jsonb);

-- Y un dependiente declarado DOS veces. Este caso existe por el defecto que lo
-- destapo: la primera version emitia el pivote sin sus dependientes cuando no
-- estaban tambien en fields, y salia una gramatica valida a la que le FALTABA un
-- campo. Nada fallaba; el objeto simplemente venia corto.
SELECT grammar_for('[{"name":"t","kind":"enum","values":["a"],"required":true,
     "dependents":[{"name":"c","kind":"enum","required":true,"by_value":{"a":["x"]}}]},
    {"name":"c","kind":"enum","values":["x"],"required":true}]'::jsonb);

-- Refusals, each one preferred over compiling something subtly wrong.
SELECT grammar_for('[{"name": "xs", "kind": "array", "required": true}]'::jsonb);
SELECT grammar_for('[{"name": "o", "kind": "object", "required": true, "fields": []}]'::jsonb);
SELECT grammar_for('[{"name": "o", "kind": "object", "required": true, "fields":
    [{"name": "a", "kind": "string", "required": false}]}]'::jsonb);
SELECT grammar_for('[{"name": "v", "kind": "enum", "values": [], "required": true}]'::jsonb);
SELECT grammar_for('[]'::jsonb);
SELECT grammar_for('[{"name": "v", "kind": "enum", "values": ["x"], "required": true}]'::jsonb, 'lark');

-- The jsonb fingerprint ignores how the spec was written, which is what makes
-- approve() usable: the same world approved twice must not read as drift.
SELECT grammar_fingerprint('[{"name":"t","kind":"enum","values":["a"],"required":true}]'::jsonb)
     = grammar_fingerprint('[{"kind":"enum","name":"t","required":true,"values":["a"]}]'::jsonb)
       AS key_order_ignored;

-- And the guard half works on the nested spec too, in both directions.
SELECT count(*) AS breaks FROM check_grammar('nested',
    '[{"name":"t","kind":"enum","values":["a"],"required":true}]'::jsonb);

SELECT approve('nested', '[{"name":"t","kind":"enum","values":["a"],"required":true}]'::jsonb)
       IS NOT NULL AS approved;

SELECT count(*) AS breaks FROM check_grammar('nested',
    '[{"name":"t","kind":"enum","values":["a"],"required":true}]'::jsonb);

SELECT name, severity FROM check_grammar('nested',
    '[{"name":"t","kind":"enum","values":["a","b"],"required":true}]'::jsonb);

DROP SCHEMA gg_test CASCADE;
DROP EXTENSION pg_grammar_guard CASCADE;

-- ------------------------------------------------------------- the upgrade --
-- The path that matters for anyone already on 0.1.0. Without this test the
-- upgrade script could be broken and nobody would find out until a user ran it
-- -- and the only alternative for them would be DROP + CREATE, which takes
-- approved_grammars with it: exactly the baselines the guard half exists to keep.
CREATE EXTENSION pg_grammar_guard VERSION '0.1.0';
SELECT approve('survives', ARRAY[ROW('t', 'enum', ARRAY['a'], true)]::grammar_field[],
               'gbnf', 'approved before the upgrade') IS NOT NULL AS approved_on_0_1_0;

ALTER EXTENSION pg_grammar_guard UPDATE TO '0.2.0';
SELECT extversion FROM pg_extension WHERE extname = 'pg_grammar_guard';

-- The baseline is still there, and the flat API still answers.
SELECT name, note FROM approved_grammars WHERE name = 'survives';
SELECT count(*) AS breaks FROM check_grammar('survives',
    ARRAY[ROW('t', 'enum', ARRAY['a'], true)]::grammar_field[]);

-- And the new one answers too.
SELECT grammar_for('[{"name":"v","kind":"enum","values":["x"],"required":true}]'::jsonb);

DROP EXTENSION pg_grammar_guard CASCADE;

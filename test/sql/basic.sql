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

DROP SCHEMA gg_test CASCADE;
DROP EXTENSION pg_grammar_guard CASCADE;

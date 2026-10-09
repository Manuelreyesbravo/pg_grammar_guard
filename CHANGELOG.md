# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_grammar_guard/). Each
upgrade script (`pg_grammar_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

## 0.4.7 -- 2026-10-09

From an external audit of 0.4.5, each finding measured on 0.4.6 before it was changed
(`test/audit.sh`, `make check-audit`, in `make check-suites`: every tooth red on 0.4.6
with its control green).

* **GG-01: a `grammar_guard` schema someone else created is refused.** `CREATE EXTENSION`
  used it silently, and its owner's `to_json(text)` ran in place of `pg_catalog`'s as
  whoever called -- a superuser, measured. The install refuses a schema owned by a role
  that is neither the installer nor a superuser, and every function searches
  `pg_catalog` first.
* **GG-02: a table with capitals is its own table.** `catalog_tables()` returned names
  unquoted, so `"Clientes"` was read back as `clientes`: the grammar offered another
  table's columns, and drift in `"Clientes"` read `holds`. Names are quoted identifiers
  now; lower-case names come out as before.
* **GG-04: `catalog_tables()` is ordered** by schema and name. `ORDER BY 1` inside an
  aggregate orders by a constant, so the list followed pg_class's physical order and
  churn or a restore read as drift. **A watch approved over `catalog_tables()` may read
  `broken` once after the upgrade**, if it was approved with another order; the upgrade
  names those watches. Re-approve the ones that do.
* **GG-03: a watch runs as the role that declared it**, through pg_living_assertions
  0.5.8, which this version requires (the tooth is red against 0.5.7).
* `test/cluster.sh` loads pg_living_assertions from `LIVING_ASSERTIONS_DIR` when set.

## 0.4.6 -- 2026-10-08

* **Metadata only.** The PGXN description is two sentences now; the longer
  explanation it carried is in this README. No code changed: the upgrade
  script 0.4.5 -> 0.4.6 changes no object.

## 0.4.5 -- 2026-10-08

* **A temporary table of the session that evaluates a grammar can no longer hide
  that the catalog drifted.** `catalog_columns()`, `catalog_tables()` and
  `catalog_enum()` read `pg_attribute`, `pg_class` and `pg_enum` without a schema,
  and no function here named `pg_temp`, which PostgreSQL then searches first for
  tables: a temporary `pg_attribute` -- a copy of the real one minus a new column
  -- made the live catalog read as the approved one. That matters when the
  evaluation runs in someone else's session with the owner's rights -- a
  `SECURITY DEFINER` function that runs the assertion `watch()` declared, as
  pg_agent_gate does inside an agent's commit (an agent allowed DDL can keep such
  a copy). Measured on 0.4.4 (`test/pg_temp.sh`, `make check-pgtemp`): an
  unapproved column read `broken`, and `holds` with that copy. Every function now
  names `pg_temp` last. No table changes.

## 0.4.4 -- 2026-10-06

* **License: Apache License 2.0**, replacing the PostgreSQL License, from this
  release on. Every version up to and including 0.4.3, already published,
  stays under the PostgreSQL License it was released with. No code changed.

## 0.4.3

Completes the copyright and licensing files: the copyright holder's full legal
name in LICENSE and README, and a per-file SPDX header on every SQL source
file. No schema change.

## 0.4.2

No schema change. Adds project governance and legal files (NOTICE, AUTHORS,
SECURITY, CONTRIBUTING, TRADEMARK). The database objects are byte-for-byte those
of 0.4.1; the `0.4.1--0.4.2` upgrade is empty on purpose.

## 0.4.1 and earlier

See the header of each `pg_grammar_guard--*--*.sql` upgrade script and the
release notes on PGXN.

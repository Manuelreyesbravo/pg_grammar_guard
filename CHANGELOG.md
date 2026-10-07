# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_grammar_guard/). Each
upgrade script (`pg_grammar_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

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

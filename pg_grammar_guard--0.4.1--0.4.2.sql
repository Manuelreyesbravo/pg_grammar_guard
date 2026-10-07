-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_grammar_guard 0.4.1 -> 0.4.2
--
-- No schema change. This release adds project governance and legal files
-- (NOTICE, AUTHORS, SECURITY, CONTRIBUTING, TRADEMARK) and nothing that runs in
-- the database. The upgrade is empty on purpose: the objects a user has after
-- ALTER EXTENSION ... UPDATE TO '0.4.2' are exactly those of 0.4.1, which is
-- what ci/upgrade_check.sh verifies member by member against a fresh install.

# Security

## Reporting a vulnerability

**Do not open a public issue.** Report it privately, by either:

* GitHub's private vulnerability reporting: the **Security** tab of this
  repository, then **Report a vulnerability**; or
* email to **manuelreyesbravo@gmail.com**, subject starting with
  `[pg_grammar_guard security]`.

Please include the PostgreSQL version, the pg_grammar_guard version (`SELECT
extversion FROM pg_extension WHERE extname = 'pg_grammar_guard'`), and the
smallest sequence of statements that shows it. A case in the style of
`test/sql/*.sql` is ideal, because it becomes a regression test.

You will get an acknowledgement within 72 hours. A confirmed issue is fixed
before it is disclosed, gets a regression case, and is credited to you in the
CHANGELOG unless you prefer otherwise.

## What counts

This extension compiles a grammar from the live catalog and reports when the
database has drifted from a baseline you approved. The report this project most
wants is a way to make it answer that nothing drifted when something did, or a
way for a role to read, store or alter a baseline or the recorded history it
should not be able to.

## Supported versions

The latest release. Fixes are not backported while the project is pre-1.0.

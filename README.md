# pg_grammar_guard

[![CI](https://github.com/Manuelreyesbravo/pg_grammar_guard/actions/workflows/ci.yml/badge.svg)](https://github.com/Manuelreyesbravo/pg_grammar_guard/actions/workflows/ci.yml)

Compiles a **token-level grammar from your live catalog**, so a constrained model
cannot name a table, a column or a value that does not exist — and tells you when
a grammar you approved stopped describing your database.

```sql
CREATE EXTENSION pg_grammar_guard CASCADE;   -- CASCADE: it needs pg_living_assertions

SELECT grammar_guard.grammar_for_json(ARRAY[
    ROW('table',  'enum', grammar_guard.catalog_tables(ARRAY['app']), true),
    ROW('column', 'enum', grammar_guard.catalog_columns('app.customers'), true),
    ROW('limit',  'integer', NULL, false)
]::grammar_guard.grammar_field[]);
```
```
root ::= "{" ws "\"table\"" ws ":" ws f1-table ws "," ws "\"column\"" ws ":" ws f2-column ws ( "," ws "\"limit\"" ws ":" ws f3-limit ws )? "}"
f1-table ::= "\"app.customers\"" | "\"app.invoices\""
f2-column ::= "\"id\"" | "\"tax_id\"" | "\"name\""
f3-limit ::= integer
...
```

Feed that to `llama.cpp` (`grammar`), or to another sampler that reads GBNF. The
model is now **unable** to emit `app.customers.email` when there is no such column.
Not corrected afterwards — unable. (`bench/grammar_check.sh` runs this grammar
through llama.cpp's GBNF parser: a `tax_id` is accepted, an `email` refused.)

## The failure it exists for

Everyone believes structured output stops a model from inventing things about
their database. **It does not.**

A JSON Schema guarantees the JSON parses and that `column` is a string. It cannot
guarantee the string is a column that **exists**, because a schema document is
written once and your catalog changes on every migration. So the model returns
`{"table": "customers", "column": "email_address"}`, perfectly valid against the
schema, and your query fails at runtime — or worse, silently returns nothing
because the name happened to match something else.

The distinction this extension is built on:

> A grammar constrains **form**. In the general case form is not truth.
> But for identifiers **form is truth**, because the set of valid names is
> finite and only PostgreSQL knows it right now.

That is the part a schema file cannot do and a database can.

## What it does not do

It makes the **nonexistent** unreachable. It does **not** make the answer right.
A model constrained to your ten real tables will still pick the wrong one of the
ten, and this extension will happily emit that. Anything that promises otherwise
is promising more than a grammar can deliver.

It also does not generate a grammar for SQL itself. Enumerating names is the part
where the catalog is the only source of truth; parsing SQL is a solved problem
that does not need to live in your database.

## Nested shapes, and the loop that hides in an array

Real tool calls are not flat. `grammar_for` takes a JSON spec and recurses:

```sql
SELECT grammar_guard.grammar_for('[
  {"name": "action",  "kind": "enum", "values": ["select","count"], "required": true},
  {"name": "columns", "kind": "array", "required": true, "max_items": 3,
   "items": {"kind": "enum", "values": ["id","amount"]}},
  {"name": "filter",  "kind": "object", "required": false, "fields": [
     {"name": "column", "kind": "enum", "values": ["id"], "required": true},
     {"name": "op",     "kind": "enum", "values": ["=","<"], "required": true}]}
]'::jsonb);
```

Whatever a model constrained by that grammar is asked -- *"drop every table in
production"*, say -- what it can emit looks like this:

```json
{"action":"select","columns":["id","id","id"],"filter":{"column":"id","op":"="}}
```

It cannot say `drop`, because `drop` is not in the enum, nor list a fourth column.
`bench/grammar_check.sh` checks all three against llama.cpp's GBNF parser: the line
above is accepted, an `"action":"drop"` and a four-item `columns` are refused.

**Arrays are always bounded, and that is not a detail.** An unbounded `( ... )*`
is a loop waiting to happen. The first version of this feature had one, and a
model emitted `["id","id","id", …]` over and over until it ran out of budget —
every single token legal under the grammar.

That is the worst failure a grammar can have, because **it does not fail**. A
model stuck in a legal loop looks exactly like a model working: no error, no
invalid output, just tokens.

The bounds came from looking at real array arguments of a working system (a
private log, not published, so not reproducible from this repo): most were short,
a few were several times longer than 16 items, and some were legitimately
**empty**. So `max_items` defaults to 32 and `min_items` to 1, both overridable,
and a field that may be empty should say `"min_items": 0`. The first draft capped
at 16 and required at least one element: it would have silently truncated the long
ones and made a legitimate empty list unreachable. **A cap that truncates real work
gets worked around instead of used** — the same failure as the unbounded array, in
the other direction.

A cap still has to exist, and the trade is deliberate: **truncating is far less
bad than never stopping**, because a short array is still valid, closed JSON that
the caller can see is short.

An object with every subfield optional, an array without `items`, and an enum
with no values are all **refused** rather than compiled — each of them produces a
grammar that is either unsatisfiable or subtly wrong about commas.

## Which fields are worth constraining at all

This is the part no grammar tool tells you, and getting it wrong is how a grammar
starts rejecting correct answers.

A field belongs in the grammar only if its set of legal values is **complete** —
something the catalog knows *in full*, right now:

| | examples | put it in |
|---|---|---|
| **closed** | table names · the columns of a given table · an enum's labels · the argument names of a known function | **the grammar** |
| **open** | file paths · shell commands · free text · arbitrary SQL | **your validator**, always |

Enumerating an open set looks like it works and quietly caps out. On a private log
of file operations (not published), an enumeration of the paths seen so far never
covered all of the next ones, however large the window: the share it missed was
the share of paths being seen for the first time. Any system that is actually
working keeps creating new ones.

So the rule is not "enumerate more". It is: **enumerate what is complete, validate
what is not.** A grammar built over an open set does not fail loudly — it makes
the correct answer unreachable, and you find out from a user, not from a log.

One consequence worth stating: constraining a field also makes it **silent**. A
validator that rejects leaves a record you can count; a grammar that forbids
leaves nothing, because the token is never emitted. Store `grammar_fingerprint`
alongside whatever you log, so you can at least answer *what space did the model
have* after the fact.

## The guard half

A grammar generated last month, against a schema migrated last week, still
constrains. It still looks like it is protecting you. And what it permits is no
longer your database — it quietly allows a dropped column and quietly forbids a
new one. No error, no log line.

Since **0.3.0** this half is not implemented here. It is
[`pg_living_assertions`](https://pgxn.org/dist/pg_living_assertions/), which
this extension requires.

```sql
-- once, when you are happy with it. Note it takes the QUERY, not the spec.
SELECT grammar_guard.watch('answer_v1',
    $$select jsonb_build_array(grammar_guard.catalog_correlated(
               ARRAY['public.invoices', 'public.customers']))$$,
    'shipped 2026-09-03');

-- in CI, or from a monitor
SELECT grammar_guard.check_grammar('answer_v1');   -- holds | broken | erroring | …
SELECT * FROM living_assertions.status;            -- with the age of each verdict
```

**Taking the query rather than the spec is the point, and it fixes a real
defect.** Up to 0.2.0 the call was `check_grammar(name, fields)` -- the *caller*
brought the world with them. Hand it a spec built from a stale variable and it
compared your baseline against something that was not your catalog and reported
no drift, cheerfully. Storing the query means the check rebuilds the grammar
from the live catalog every time it runs, so a cron job, a deploy gate, or
somebody who was not there when it was approved all get a real answer.

`never_approved` has not been lost: it is `living_assertions.state()` answering
`unregistered`, alongside `unchecked` (declared but never run), `unknown` and
`erroring`. Four extensions had each invented their own word for that same
distinction; it is now solved once. And every verdict is reported with **how old
it is** -- a stale `holds` reads exactly like a fresh one and means something
else entirely.

### Upgrading from 0.2.0

`ALTER EXTENSION pg_grammar_guard UPDATE TO '0.3.0'` **warns** if you had
baselines, and it cannot port them: 0.2.0 stored a fingerprint and never the
query that rebuilds the spec, so nothing can re-check them. They are kept in
`grammar_guard.baselines_from_0_2_0` -- the only record of what you had approved
-- and each needs `watch()` naming its query again. An upgrade that left you
silently unwatched would be this extension's own subject matter happening to its
users.

## Correlation — the column depends on the table

A flat grammar happily permits this:

```json
{"table": "invoices", "column": "name"}
```

where `name` belongs to `customers`. **Well formed and impossible** — exactly what
this extension exists to make unreachable. One call builds it from the catalog:

```sql
SELECT grammar_guard.grammar_for(jsonb_build_array(
    grammar_guard.catalog_correlated(ARRAY['app.customers', 'app.invoices'])));
```
```
root ::= "{" ws "\"table\"" ws ":" ws "\"app.customers\""  ws "," … root-v0-d0 ws "}"
       | "{" ws "\"table\"" ws ":" ws "\"app.invoices\"" ws "," … root-v1-d0 ws "}"
root-v0-d0 ::= "\"id\"" | "\"tax_id\"" | "\"name\""
root-v1-d0 ::= "\"id\"" | "\"customer_id\"" | "\"amount\""
```

One alternative per table, so the legal columns are chosen by the token the model
**already emitted**. A column that exists in the database but not in that table is
not a legal continuation, so a constrained model cannot produce it, however it is
asked. `bench/grammar_check.sh` shows it with llama.cpp's GBNF parser over a
generated schema:

| input | flat grammar | correlated grammar |
|---|---|---|
| a column of the chosen table | accepted | accepted |
| **a column of another table** | accepted | **refused** |
| a column that exists nowhere | refused | refused |

Only **one** field per object may carry dependents. Two would need an alternative
per *combination*, which is the exponential blowup people expect here — it is
refused rather than quietly emitted. And a pivot value with no legal dependents
is refused too: an unsatisfiable branch is worse than a missing one, because the
model can enter it and then have no legal token left.

## Where it runs, and how big it gets

`gbnf` is the grammar format of llama.cpp, and the grammars here are checked
against its parser (`bench/grammar_check.sh`). XGrammar, the structured-generation
backend of vLLM and SGLang among others, documents support for the same format; that
is not checked in this repo.

Size, measured with `bench/grammar_check.sh` over a generated schema (each table has
`id`, `created_at` and four columns of its own; results and machine in
`bench/results.md`):

| schema | flat: table enum + column enum | correlated: columns depend on the table |
|---|---|---|
| 81 tables, 326 distinct columns, 486 pairs | 7.9 KB | 18.1 KB |
| 200 tables, 802 distinct columns, 1,200 pairs | 19.4 KB | 44.6 KB |

So a correlated grammar costs about **2.3×** the flat one, and grows with the number
of (table, column) pairs rather than exploding. But it does grow, and a grammar of
tens of kilobytes is a lot to hand a sampler on every request.

**Constrain a subset, not the whole catalog.** Pass the tables the request could
plausibly touch. That is not a workaround for a limitation — a grammar listing
every table in the database is the oversized tool schema all over again, and the
whole point here is to hand the model a small true world instead of a big one.

## Dialects

| dialect | enforced by | invalid values are |
|---|---|---|
| `gbnf` | the sampler, token by token | **unreachable** |
| `json_schema` | a validator, after generation | rejected once produced |

Both carry the same live enums, so `json_schema` is still worth more than a
hand-written schema. But only `gbnf` makes the wrong name impossible, and the
difference is stated here rather than glossed over.

The `gbnf` object has a **fixed key order**: required fields in the order given,
then optional ones. That is what keeps comma placement decidable, and it is why
a set of fields where every field is optional is refused instead of being
compiled into something subtly wrong.

## Tested on

0.4.9 was measured on 2026-11-12, not assumed, on local builds of PostgreSQL 11.22,
12.22, 13.23, 14.24, 15.19, 16.15, 17.11, 18.6 and 19rc1: `make installcheck` and
`ci/upgrade_check.sh` from every earlier release on each, and `make check-suites`
(`check-pgtemp`, `check-audit`) on 18 and 19. All green. The installcheck also passes
with pg_living_assertions 0.5.6, the oldest version this extension accepts (on 11
and 19). The CI in `.github/workflows` runs installcheck and the upgrade check on 11
to 19.

| 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |
|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| ✗  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  |

11 and 12 arrived with 0.4.1.  Before that, `catalog_columns()` and
`catalog_enum()` aggregated a `name` column into an array while declaring
`text[]`, which only 13 and later accept; every call raised "return type
mismatch" on 12 and earlier.

PostgreSQL 10 is out because pg_living_assertions, which this extension needs,
requires 11.

## Install

It needs **pg_living_assertions 0.5.6 or later** (0.5.10 recommended) installed in
the same PostgreSQL; `make install` here does not install it. From PGXN:

```
pgxn install pg_living_assertions
pgxn install pg_grammar_guard
psql -c 'CREATE EXTENSION pg_grammar_guard CASCADE'
```

From source, with pg_living_assertions already installed (`make install` in its
checkout):

```
make install
psql -c 'CREATE EXTENSION pg_grammar_guard CASCADE'
make installcheck   # against the server your PG* variables point at
```

`CASCADE` creates pg_living_assertions in the database if it is not there yet;
without it, `CREATE EXTENSION` stops with `required extension
"pg_living_assertions" is not installed`.

Pure SQL. No shared library, and it reads only the catalogs — because the
database that most needs a grammar built from its real schema is usually the one
where installing a C extension is hardest to get approved.

**Privileges.** Every function is executable by `PUBLIC`: they only read the
catalog and return text, so a role learns nothing it could not read from
`pg_catalog` itself. `watch()` writes through `pg_living_assertions.declare()`,
and so only for a role you granted that to.

Every function sets its own `search_path`. Not style: the extension installs into
its own schema, so an unqualified reference would resolve through the *caller's*
`search_path` — which fails at runtime for anyone who has not added the schema,
and lets a caller decide which `md5` the fingerprint uses. Since 0.4.7 that path
starts with `pg_catalog`.

**Create the `grammar_guard` schema yourself, or let the extension create it.**
Since 0.4.7 `CREATE EXTENSION` refuses a `grammar_guard` schema owned by a role
that is neither the installer nor a superuser. Until 0.4.6 it used one silently,
and its owner could define, say, `to_json(text)` there and have it run with the
rights of whoever called the extension -- a superuser, in the external audit.
Path order alone does not stop that: PostgreSQL picks the best-matching overload
whatever schema it lives in.

Since 0.4.8 `watch()` keeps no path of its own: the spec is resolved with its
author's `search_path`, recorded with the assertion and applied with `pg_temp`
last -- at approval too, so a temporary table of the approving session is not what
gets approved. Qualifying names in a spec is still the robust way to write one.

A watch runs as the role that declared it with pg_living_assertions 0.5.8 or
later: a role you let call `watch()` can make a check read only what it can read
itself, not what the role running `check_grammar()` can. On 0.5.6 and 0.5.7 a check
still runs as whoever runs it, which is one reason to install 0.5.10.

## License

Apache License 2.0 -- see [LICENSE](LICENSE). Copyright 2026 Manuel Reyes Bravo.

The name is not licensed with the code: see [TRADEMARK.md](TRADEMARK.md).

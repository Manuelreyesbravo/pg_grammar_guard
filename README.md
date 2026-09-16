# pg_grammar_guard

Compiles a **token-level grammar from your live catalog**, so a constrained model
cannot name a table, a column or a value that does not exist — and tells you when
a grammar you approved stopped describing your database.

```sql
CREATE EXTENSION pg_grammar_guard;

SELECT grammar_guard.grammar_for_json(ARRAY[
    ROW('table',  'enum', grammar_guard.catalog_tables(ARRAY['app']), true),
    ROW('column', 'enum', grammar_guard.catalog_columns('app.clientes'), true),
    ROW('limit',  'integer', NULL, false)
]::grammar_guard.grammar_field[]);
```
```
root ::= "{" ws "\"table\"" ws ":" ws f1-table ws "," ws "\"column\"" ws ":" ws f2-column ws ( "," ws "\"limit\"" ws ":" ws f3-limit ws )? "}"
f1-table ::= "\"app.clientes\"" | "\"app.facturas\""
f2-column ::= "\"id\"" | "\"rut\"" | "\"nombre\""
f3-limit ::= integer
...
```

Feed that to `llama.cpp` (`grammar`), or to anything built on llguidance or
XGrammar. The model is now **unable** to emit `app.clientes.email` when there is
no such column. Not corrected afterwards — unable.

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
   "items": {"kind": "enum", "values": ["id","monto"]}},
  {"name": "filter",  "kind": "object", "required": false, "fields": [
     {"name": "column", "kind": "enum", "values": ["id"], "required": true},
     {"name": "op",     "kind": "enum", "values": ["=","<"], "required": true}]}
]'::jsonb);
```

Asked to *"drop every table in production"*, a 35B constrained by that grammar
answered:

```json
{"action":"select","columns":["id","id","id"],"filter":{"column":"id","op":"="}}
```

It could not say `drop`, because `drop` is not in the enum.

**Arrays are always bounded, and that is not a detail.** An unbounded `( ... )*`
is a loop waiting to happen. The first version of this feature had one, and the
same model emitted `["id","id","id", …]` **forty-one times** until it ran out of
budget — every single token legal under the grammar.

That is the worst failure a grammar can have, because **it does not fail**. A
model stuck in a legal loop looks exactly like a model working: no error, no
invalid output, just tokens.

The bounds are **measured, not chosen**. Over 721 real array arguments taken from
a working system: 95th percentile **9** items, largest **84**, and — the part
that mattered — a real minimum of **zero**. So `max_items` defaults to 32 and
`min_items` to 1, both overridable. The first draft capped at 16 and required at
least one element: it would have silently truncated that 84 and made a legitimate
empty list unreachable. **A cap that truncates real work gets worked around
instead of used** — the same failure as the unbounded array, in the other
direction.

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

Enumerating an open set looks like it works and quietly caps out. Measured on a
real workload of 1.024 operations over 165 distinct file paths: a window of the
last 12 paths covers 68% of them, and **no window size ever reaches 100%** — the
curve saturates at 83,9%, which is exactly the share of paths being seen for the
first time. Any system that is actually working keeps creating new ones.

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
{"table": "facturas", "column": "nombre"}
```

where `nombre` belongs to `clientes`. **Well formed and impossible** — exactly what
this extension exists to make unreachable. One call builds it from the catalog:

```sql
SELECT grammar_guard.grammar_for(jsonb_build_array(
    grammar_guard.catalog_correlated(ARRAY['app.clientes', 'app.facturas'])));
```
```
root ::= "{" ws "\"table\"" ws ":" ws "\"app.clientes\""  ws "," … root-v0-d0 ws "}"
       | "{" ws "\"table\"" ws ":" ws "\"app.facturas\"" ws "," … root-v1-d0 ws "}"
root-v0-d0 ::= "\"id\"" | "\"rut\"" | "\"nombre\""
root-v1-d0 ::= "\"id\"" | "\"cliente_id\"" | "\"monto\""
```

One alternative per table, so the legal columns are chosen by the token the model
**already emitted**. Asked point blank for a column that exists in the database
but not in that table, a local 35B could not produce it:

| asked for | emitted |
|---|---|
| `path` from `public.projects` | `{"table":"public.projects","column":"path"}` |
| **`db_connection` from `public.nodes`** — it is a column of `projects` | `{"table":"public.nodes","column":"id"}` |
| `inventada_xyz` from `public.projects` | `{"table":"public.projects","column":"id"}` |

Only **one** field per object may carry dependents. Two would need an alternative
per *combination*, which is the exponential blowup people expect here — it is
refused rather than quietly emitted. And a pivot value with no legal dependents
is refused too: an unsatisfiable branch is worse than a missing one, because the
model can enter it and then have no legal token left.

## Where it runs, and how big it gets

`gbnf` is not a llama.cpp-only format. **XGrammar** — the default structured
generation backend of **vLLM**, **SGLang**, **TensorRT-LLM** and **MLC-LLM** —
follows the same GBNF specification. Checked rather than assumed: every grammar
in this README, plus a real 81-relation catalog, compiles under
`xgrammar.Grammar.from_ebnf` (**5/5**) and under llama.cpp.

Size, measured on that same real catalog (81 relations, 410 distinct columns):

| | bytes |
|---|---|
| flat: table enum + column enum | **10.9 KB** |
| correlated: columns depend on the chosen table | **22.2 KB** |

So a correlated grammar costs about **2×** the flat one, and stays linear in the
number of (table, column) pairs rather than exploding. But it does grow: at this
rate a **200-relation schema lands near 55 KB**, which is a lot to hand a sampler
on every request.

**Constrain a subset, not the whole catalog.** Pass the tables the request could
plausibly touch. That is not a workaround for a limitation — a grammar listing
every table in the database is the 45k-token tool schema all over again, and the
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

Measured on 2026-09-16, not assumed: `make installcheck` was run against each
of these releases, every one in a container of the official image for that
version (19beta2 is a local build).

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

```
make install
psql -c 'CREATE EXTENSION pg_grammar_guard'
```

Pure SQL. No shared library, no dependencies, and it reads only the catalogs —
because the database that most needs a grammar built from its real schema is
usually the one where installing a C extension is hardest to get approved.

Every function sets its own `search_path`. Not style: the extension installs into
its own schema, so an unqualified reference would resolve through the *caller's*
`search_path` — which fails at runtime for anyone who has not added the schema,
and lets a caller decide which `md5` the fingerprint uses.

## Measured

Against a local 35B (`llama.cpp`), eight prompts written to tempt the model into
naming things that do not exist — a `deploy` capability, a `zently` project, a
`terraform apply`:

| | valid output |
|---|---|
| with the generated grammar | **8/8** |
| without it (control) | **0/8** |

The control is the part that matters: without it, a grammar that did nothing at
all would have scored the same 8/8 on easy prompts. Unconstrained, the model
returned fenced markdown, a project description, and a bash command.

And consistent with the section above: constrained, it answered "deploy to
production" with a real capability that was the **wrong** one. Well formed,
wrong. That is the boundary of what a grammar buys.

## Licence

PostgreSQL Licence.

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

```sql
-- once, when you are happy with it
SELECT grammar_guard.approve('answer_v1', my_fields, 'gbnf', 'shipped 2026-09-03');

-- in CI, or from a monitor
SELECT * FROM grammar_guard.check_grammar('answer_v1', my_fields);
```
```
    name    |                    detail                     | severity
------------+-----------------------------------------------+----------
 answer_v1  | the approved grammar no longer describes the…  | drift
```

An empty result means the grammar you approved still matches the world.
`never_approved` is reported as its own severity and never as `drift`: a grammar
nobody approved is not one that changed, and collapsing the two is how a monitor
starts reporting something it cannot know.

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

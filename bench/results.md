# bench/grammar_check.sh results

- Date: 2026-11-12
- Code: pg_grammar_guard 0.4.9 (the SQL of tag v0.4.9); `bench/grammar_check.sh` as committed
  in 18dd4c5.
- PostgreSQL 13.23, built from `REL_13_STABLE` 05f6c9ec2c4, `CFLAGS=-O2`, no assertions.
- GBNF parser: llama.cpp `test-gbnf-validator` (`build_vulkan`, source tree at c46758d).
- Machine: AMD Ryzen AI 9 HX 370, Fedora, Linux 7.3.3. Sizes do not depend on the machine.
- Commands:
  `GBNF_VALIDATOR=<llama.cpp>/build_vulkan/bin/test-gbnf-validator bash bench/grammar_check.sh`
  and `TABLES=200 bash bench/grammar_check.sh`, each against a throwaway server.

## Size

Each generated table has `id`, `created_at` and four columns of its own (`EXTRA=4`).

| tables | distinct columns | (table, column) pairs | flat gbnf | correlated gbnf | flat json_schema |
|---|---|---|---|---|---|
| 81 | 326 | 486 | 7,942 B | 18,140 B | 12,618 B |
| 200 | 802 | 1,200 | 19,366 B | 44,639 B | 30,587 B |

## GBNF acceptance (81 tables)

12 of 12 inputs answered as expected:

| grammar | input | expected and got |
|---|---|---|
| flat | a column of the chosen table | accepted |
| correlated | a column of the chosen table | accepted |
| flat | a column of another table | accepted |
| correlated | a column of another table | refused |
| flat | a column that exists nowhere | refused |
| correlated | a column that exists nowhere | refused |
| correlated | a table that exists nowhere | refused |
| README quickstart | `tax_id` of `readme.customers` | accepted |
| README quickstart | `email` of `readme.customers` | refused |
| README nested spec | the JSON line shown in the README | accepted |
| README nested spec | `"action":"drop"` | refused |
| README nested spec | four items in `columns` (`max_items` 3) | refused |

These replace figures the README carried without a script or record behind them: sizes of
10.9 KB / 22.2 KB over a private 81-relation catalog, an extrapolated 55 KB at 200 relations,
"5/5" under XGrammar, and the answers of a local 35B model (8/8 against 0/8, and a table of
three prompts). No language model was run for this file.

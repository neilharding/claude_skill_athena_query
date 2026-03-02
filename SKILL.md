---
name: athena-query
description: Use when the user asks to query AWS Athena, run Athena SQL, or fetch data from Athena databases
---

# Athena Query Skill

Execute SQL queries against AWS Athena and return results as structured data.

## Prerequisites

The user must have run `./setup.sh` in this skill's directory to configure AWS credentials and Athena connection settings. If queries fail with configuration errors, tell the user to run:

```bash
cd ~/.claude/skills/athena-query && ./setup.sh
```

## How to Run Queries

Execute queries using the skill's Python runner:

```bash
~/.claude/skills/athena-query/.venv/bin/python ~/.claude/skills/athena-query/scripts/run_query.py "YOUR SQL QUERY HERE"
```

### CLI Options

- `--profile PROFILE` — Use a specific AWS/Athena profile (e.g., `--profile prod`). Without this flag, the default profile (usually `dev`) is used.
- `--params '["val1", "val2"]'` — Positional query parameters for `?` placeholders.
- `--format csv|json|table` — Output format. Default is `csv`. Use `table` for display, `json` for structured parsing.
- `--timeout SECONDS` — Query timeout (default: 600).

### Examples

Simple query:
```bash
~/.claude/skills/athena-query/.venv/bin/python ~/.claude/skills/athena-query/scripts/run_query.py "SELECT * FROM my_table LIMIT 10"
```

Query with a specific profile:
```bash
~/.claude/skills/athena-query/.venv/bin/python ~/.claude/skills/athena-query/scripts/run_query.py "SELECT count(*) FROM patients" --profile prod
```

Parameterized query:
```bash
~/.claude/skills/athena-query/.venv/bin/python ~/.claude/skills/athena-query/scripts/run_query.py "SELECT * FROM events WHERE status = ?" --params '["active"]'
```

## Multi-Profile Support

The skill supports multiple AWS/Athena profiles (e.g., dev, prod). Each profile has its own AWS credentials and Athena settings (database, workgroup, region, S3 output location).

- Default profile is used when no `--profile` flag is passed
- When the user says "query prod" or "use the production database", pass `--profile prod`
- When the user says "query dev" or doesn't specify, use the default (no `--profile` flag needed)

## SQL Dialect Notes

Athena uses Trino/Presto SQL syntax:

- **Parameters:** Use `?` for positional placeholders, pass values via `--params` as a JSON list
- **REGEXP_LIKE:** Two parameters only: `REGEXP_LIKE(column, '(?i)pattern')` — use `(?i)` prefix for case-insensitive
- **String functions:** `LOWER()`, `UPPER()`, `TRIM()`, `SUBSTR()`
- **Date functions:** `DATE()`, `DATE_ADD()`, `DATE_DIFF()`, `CURRENT_DATE`
- **LIMIT:** `LIMIT N` at end of query
- **NULL handling:** `IS NULL`, `IS NOT NULL`, `COALESCE()`

## Presenting Results

- For small results (< 20 rows): show the full table
- For medium results (20-100 rows): show first 10 rows and summarize (total rows, columns, notable patterns)
- For large results (100+ rows): show first 5 rows, summarize, and offer to save to a file
- Always mention the row count and execution time (both printed to stderr by the runner)
- If the user asks for analysis, use the data to answer their question directly

## Error Handling

- **"Run ./setup.sh to configure"** — skill isn't set up yet, guide the user
- **Connection/credential errors** — suggest checking AWS profile config: `aws sts get-caller-identity --profile <name>`
- **Query timeout** — suggest adding `LIMIT`, optimizing the query, or increasing `--timeout`
- **SQL syntax errors** — Athena returns clear error messages, relay them to the user

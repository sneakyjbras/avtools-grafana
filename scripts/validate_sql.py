#!/usr/bin/env python3
"""Statically validate every SQL string embedded in the Grafana JSON.

CI's ``validate_json`` only proves the files are valid JSON — it cannot catch a
broken ``rawSql``, so a SQL syntax error ships silently and surfaces as
``db query error: ... (SQLSTATE 42601)`` in every affected panel/alert.

This harness binds the real PostgreSQL parser (``pglast`` -> libpg_query) and
parses every ``rawSql`` found anywhere in the dashboards and alert rulegroups.
Grafana template tokens (``$var``, ``${var:csv}``, ``[[var]]``, ``$__timeFilter``)
are replaced with a bare identifier before parsing, since they usually sit inside
string literals or value lists.

Usage:
    pip install pglast
    python scripts/validate_sql.py [root_dir]

Exit code 0 if every query parses, 1 otherwise (printing each failure).
"""
from __future__ import annotations

import glob
import json
import re
import sys

import pglast

# $__timeFilter(...) / ${var:csv} / [[var]] / $var  ->  a bare token `x`.
# Bare `x` (not quoted) is deliberate: the vars usually already sit inside string
# literals, and substituting `'x'` would double-quote and create false failures.
_TOKEN = re.compile(r"\$\{[^}]*\}|\[\[[^\]]*\]\]|\$__[a-zA-Z_]+|\$[a-zA-Z_]\w*")


def iter_raw_sql(node, path):
    """Yield (json_path, sql) for every ``rawSql`` string anywhere in ``node``."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "rawSql" and isinstance(value, str) and value.strip():
                yield path, value
            else:
                yield from iter_raw_sql(value, f"{path}.{key}")
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from iter_raw_sql(item, f"{path}[{i}]")


def check_file(json_path):
    """Return a list of (json_path, error) for queries in one file that fail to parse."""
    doc = json.load(open(json_path))
    failures = []
    checked = 0
    for jpath, sql in iter_raw_sql(doc, json_path):
        checked += 1
        try:
            pglast.parse_sql(_TOKEN.sub("x", sql))
        except Exception as exc:  # pglast.parser.ParseError and friends
            failures.append((jpath, str(exc).strip()))
    return checked, failures


def main(root="grafana"):
    files = sorted(glob.glob(f"{root}/**/*.json", recursive=True))
    total_checked = 0
    total_failures = []
    for json_path in files:
        checked, failures = check_file(json_path)
        total_checked += checked
        total_failures.extend((json_path, jp, err) for jp, err in failures)

    if total_failures:
        print(f"FAIL — {len(total_failures)} query(ies) did not parse:", file=sys.stderr)
        for json_path, jpath, err in total_failures:
            print(f"  {jpath}\n    {err}", file=sys.stderr)
        return 1

    print(f"OK — {total_checked} embedded SQL queries parse across {len(files)} files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1 else "grafana"))

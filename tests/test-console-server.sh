#!/usr/bin/env bash
set -uo pipefail

# Runs the console server's python unittest suite as part of the bash gate.
#
# plugin/scripts/test_singular_graph_server.py is plain `unittest` and imports
# `singular_graph_server` as a sibling module, so it needs plugin/scripts on
# sys.path. It was never wired into tests/run.sh (which globs test-*.sh), so a
# few hundred passing console assertions were invisible to the regression gate
# and to the l1-drive gate command. This wrapper closes that hole without
# changing the python suite's own entry points.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ENGINE_HOME/plugin/scripts"
SUITE="test_singular_graph_server"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SCRIPTS_DIR/$SUITE.py" ]] || fail "console suite not present: $SCRIPTS_DIR/$SUITE.py"
[[ -f "$SCRIPTS_DIR/singular_graph_server.py" ]] \
  || fail "console server not present in this checkout"

# Isolate: run from a scratch cwd so a test that touches relative paths cannot
# write into the checkout, and keep __pycache__ out of the tree.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out="$(cd "$tmp" && PYTHONPATH="$SCRIPTS_DIR" PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest "$SUITE" 2>&1)"
rc=$?

if [[ "$rc" -ne 0 ]]; then
  printf '%s\n' "$out" | tail -30 >&2
  fail "console server suite failed (exit $rc)"
fi

# unittest reports counts on stderr, folded into $out above.
count="$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | tail -1)"
[[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] \
  || fail "console server suite ran no tests (output: $(printf '%s' "$out" | tail -3))"

echo "PASS: test-console-server ($count console tests)"

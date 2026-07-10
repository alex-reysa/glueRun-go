#!/usr/bin/env bash
# Run the full engine regression suite. Exits non-zero if any test file fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
failed=""

# Generic engine suite + the gluerun-ext (opt-in module) suite, if present.
EXT_DIR="$(cd "$TESTS_DIR/../gluerun-ext/tests" 2>/dev/null && pwd || true)"
for t in "$TESTS_DIR"/test-*.sh ${EXT_DIR:+"$EXT_DIR"/test-*.sh}; do
  [[ -e "$t" ]] || continue
  name="$(basename "$t")"
  # </dev/null: no test may inherit the harness's stdin. A test that lets a
  # child read stdin (e.g. a runner mock's `cat` consuming a prompt) hangs
  # forever when the calling harness holds stdin open (detached l1-drive
  # gate) yet passes when stdin is /dev/null — harness-dependent flakiness
  # this closes for every current and future test.
  if out="$(bash "$t" </dev/null 2>&1)"; then
    printf "PASS  %s\n" "$name"
    pass=$((pass + 1))
  else
    printf "FAIL  %s\n" "$name"
    printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    fail=$((fail + 1))
    failed="$failed $name"
  fi
done

echo ""
echo "SUMMARY: $pass passed, $fail failed"
[[ -n "$failed" ]] && echo "FAILED:$failed"
[[ "$fail" -eq 0 ]]

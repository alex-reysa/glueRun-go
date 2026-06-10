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
  if out="$(bash "$t" 2>&1)"; then
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

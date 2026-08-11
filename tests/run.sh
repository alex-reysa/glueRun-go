#!/usr/bin/env bash
# Run the full engine regression suite. Exits non-zero if any test file fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
failed=""
gate_report_file="${SINGULAR_GATE_REPORT_FILE:-}"
# Durable per-run artifact directory, set by `singular test`'s supervisor. Read
# here, before the env scrub below, for the same reason gate_report_file is:
# the scrub deletes every SINGULAR_* from the environment a few lines down.
# Unset (the default, and every direct `bash tests/run.sh` invocation) means no
# per-test logs and no progress file — the output below is then byte-identical
# to what this harness has always printed.
run_dir="${SINGULAR_TEST_RUN_DIR:-}"

# Environmental preflights, before any test is discovered or run. Both fail
# once, loudly, instead of letting every dependent test fail separately.
#
#   1. Bash >= 4 (PMGO-007). The suite and the engine need it; the harness
#      itself used to invoke tests with a bare `bash`, so macOS Bash 3.2
#      produced cryptic per-test failures instead of one diagnosis. The shim
#      re-execs this script under a vetted interpreter when needed, which is
#      also why it is sourced before the env scrub below: that scrub unsets
#      SINGULAR_BASH_BOOTSTRAPPED, harmlessly, because every test is launched
#      with "$BASH" (already >= 4) and their own inline guards then no-op.
#   2. A real Git working tree with history and disposable worktrees
#      (PMGO-010). Most tests need all three; a `git archive` extraction has
#      none of them.
# shellcheck source=../engine/bash-guard.sh
. "$TESTS_DIR/../engine/bash-guard.sh" || exit 2
# shellcheck source=../engine/git-preflight.sh
. "$TESTS_DIR/../engine/git-preflight.sh" || exit 2
singular_git_source_preflight "$TESTS_DIR/.." || exit 1

# Hermetic guard: scrub inherited SINGULAR_* env. When this suite runs as the
# regression gate under l1-drive, the drive has already exported the consumer
# repo's config into the environment (SINGULAR_RUNNER, SINGULAR_AREA_PREFIX,
# SINGULAR_TARGET_BRANCH, ...) and lib.sh's ${VAR:-default} fallbacks keep the
# leaked values, so sandboxed tests see the consumer's config instead of
# pristine defaults (and a leaked SINGULAR_RUNNER replaces test runner stubs
# with a real CLI). Tests set every SINGULAR_* var they need internally.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

# Positional arguments are a basename filter: `bash tests/run.sh test-a.sh
# test-b.sh` runs only those two files. Discovery itself is untouched — the
# filter is applied to the same list, so singular-ext glob semantics still hold
# — and with no arguments (every existing caller) nothing is filtered at all.
# This is what makes `singular test --rerun-failures` possible without a second,
# divergent discovery path.
filter=" $* "

if [[ -n "$run_dir" ]]; then mkdir -p "$run_dir/logs"; fi

# Generic engine suite + the singular-ext (opt-in module) suite, if present.
EXT_DIR="$(cd "$TESTS_DIR/../singular-ext/tests" 2>/dev/null && pwd || true)"
for t in "$TESTS_DIR"/test-*.sh ${EXT_DIR:+"$EXT_DIR"/test-*.sh}; do
  [[ -e "$t" ]] || continue
  name="$(basename "$t")"
  if [[ "$#" -gt 0 && "$filter" != *" $name "* ]]; then continue; fi
  started=$SECONDS
  # </dev/null: no test may inherit the harness's stdin. A test that lets a
  # child read stdin (e.g. a runner mock's `cat` consuming a prompt) hangs
  # forever when the calling harness holds stdin open (detached l1-drive
  # gate) yet passes when stdin is /dev/null — harness-dependent flakiness
  # this closes for every current and future test.
  #
  # With a run dir the same combined stream is tee'd to a durable per-test log
  # as it is produced (an attached operator can watch a slow test grow), while
  # $out still holds it for the tail -3 display below. `set -o pipefail` (line
  # 3) is what keeps the TEST's exit status, not tee's, decisive.
  if [[ -n "$run_dir" ]]; then
    out="$("$BASH" "$t" </dev/null 2>&1 | tee "$run_dir/logs/$name.log")"; rc=$?
  else
    out="$("$BASH" "$t" </dev/null 2>&1)"; rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    printf "PASS  %s\n" "$name"
    pass=$((pass + 1))
    status="pass"
  else
    printf "FAIL  %s\n" "$name"
    printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    fail=$((fail + 1))
    failed="$failed $name"
    status="fail"
  fi
  # One JSON line per finished test, appended immediately: this is what makes a
  # run resumable-to-read — counts survive the supervisor being killed, and an
  # interrupted manifest is reconciled from exactly these lines. Test basenames
  # come from a `test-*.sh` glob and need no JSON escaping.
  if [[ -n "$run_dir" ]]; then
    printf '{"test":"%s","status":"%s","seconds":%d,"log":"logs/%s.log"}\n' \
      "$name" "$status" "$((SECONDS - started))" "$name" >>"$run_dir/progress.jsonl"
  fi
done

# A filter that matched nothing is an error, not an empty green run: silently
# reporting "0 passed, 0 failed" for a misspelled or deleted test name is the
# kind of false pass this whole command exists to eliminate.
if [[ "$#" -gt 0 && "$((pass + fail))" -eq 0 ]]; then
  echo "run.sh: no test file matched the filter:$(printf ' %s' "$@")" >&2
  exit 1
fi

echo ""
echo "SUMMARY: $pass passed, $fail failed"
[[ -n "$failed" ]] && echo "FAILED:$failed"
if [[ -n "$gate_report_file" ]]; then
  python3 - "$gate_report_file" "$failed" <<'PY'
import json
import os
import sys

path, failed = sys.argv[1:3]
failures = [
    {"signature": f"engine-regression:{name}", "title": name}
    for name in failed.split()
]
record = {
    "schema": "singular.orchestration.gate-observation.v0",
    "failures": failures,
}
temporary = path + ".tmp"
parent = os.path.dirname(path)
if parent:
    os.makedirs(parent, exist_ok=True)
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, path)
PY
fi
[[ "$fail" -eq 0 ]]

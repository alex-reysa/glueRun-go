#!/usr/bin/env bash
set -euo pipefail

# Every adapter must apply the update pin its spec row declares, on every
# invocation. The exposure is concrete: a provider CLI that installs a new
# version of itself while a run is using it swaps the executable under a
# containment-critical invocation -- the traps, the session leader and the
# kill-tree are all holding a process that is no longer the binary the run
# resolved. Only grok was pinned; the other five were not.
#
# The cases are generated from engine/providers.json, so provider N+1 is covered
# by adding its row. Each provider is driven through its real adapter with a
# mock binary that records the argv and the environment it was handed:
#   - a row with pin args must pass them, FIRST, before any other flag
#   - a row with pin env must have those variables exported into the provider
#   - a row with no pin must pass no update flag at all (an undeclared pin is a
#     fact about dispatch that the spec, doctor and the console cannot see)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-pin-test.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT
bindir="$workroot/bin"
mkdir -p "$bindir"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export SINGULAR_TARGET_BRANCH="test-target"

new_repo() {
  local d="$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && printf '.singular-state/\n' > .gitignore && git add .gitignore \
      && git commit -qm init && git branch "$SINGULAR_TARGET_BRANCH" )
}

# One mock stands in for every provider CLI: it records what it was invoked
# with, drains the prompt on stdin, and answers with a shape close enough to
# each CLI's success envelope that the adapter runs to completion. What happens
# after the recording does not matter here -- the argv and the environment are
# the evidence.
make_mock() {
  local name="$1"
  cat >"$bindir/$name" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_ARGS_OUT:-}" ]] && printf '%s\n' "$*" > "$MOCK_ARGS_OUT"
[[ -n "${MOCK_ENV_OUT:-}" ]] && env > "$MOCK_ENV_OUT"
cat >/dev/null 2>&1 || true
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"{\"ok\":true}","response":"{\"ok\":true}","text":"{\"ok\":true}","sessionId":"s1","session_id":"s1"}'
MOCK
  chmod +x "$bindir/$name"
}

# The spec is the case list: id, binary, adapter, pin args, pin env.
mapfile -t rows < <(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/engine")
import provider_spec as spec

for name in spec.names():
    entry = spec.entry(name)
    args, env = spec.update_pin(name)
    # A provider whose models are namespaced refuses to dispatch without a ref
    # in that namespace, so the case list carries a syntactically valid one.
    prefix = spec.model_listing_prefix(name)
    print("|".join([
        name,
        entry["binary"],
        entry["adapter"],
        " ".join(args),
        " ".join(f"{k}={v}" for k, v in env.items()),
        f"{entry['model']['env']}={prefix}vendor/model" if prefix else "",
    ]))
PY
)
[[ "${#rows[@]}" -ge 6 ]] || fail "spec produced ${#rows[@]} providers; expected the full set"

# Scrub every pin variable out of THIS process first. The host that runs this
# suite may already export one of them (DISABLE_AUTOUPDATER is set inside a
# Claude Code session, for instance), and an inherited value would let the test
# pass while the adapter set nothing at all -- proving the environment, not the
# engine.
mapfile -t pin_env_names < <(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/engine")
import provider_spec as spec

for name in spec.names():
    for variable in spec.update_pin(name)[1]:
        print(variable)
PY
)
if [[ "${#pin_env_names[@]}" -gt 0 ]]; then
  unset "${pin_env_names[@]}"
fi

for row in "${rows[@]}"; do
  IFS="|" read -r provider binary adapter pin_args pin_env model_env <<<"$row"
  repo="$workroot/$provider"
  new_repo "$repo"
  make_mock "$binary"
  prompt="$repo/prompt.md"; printf 'do the thing\n' >"$prompt"
  args_out="$workroot/$provider.args"
  env_out="$workroot/$provider.env"
  rm -f "$args_out" "$env_out"
  (
    cd "$repo"
    # An expanded NAME=value is a command word, not an assignment, so a
    # namespaced provider's model ref is exported rather than prefixed.
    [[ -z "$model_env" ]] || export "${model_env?}"
    PATH="$bindir:$PATH" SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
      MOCK_ARGS_OUT="$args_out" MOCK_ENV_OUT="$env_out" \
      "$ROOT/engine/$adapter" --level l2 -C "$repo" --prompt-file "$prompt" \
      --output-last-message "$workroot/$provider.out.json"
  ) >/dev/null 2>&1 || true
  [[ -f "$args_out" ]] || fail "$provider: adapter never invoked $binary"

  recorded="$(cat "$args_out")"
  if [[ -n "$pin_args" ]]; then
    [[ "$recorded" == "$pin_args"* ]] \
      || fail "$provider: pin '$pin_args' must come first (got: $recorded)"
    pass "$provider passes its update pin first: $pin_args"
  else
    # No declared pin means no pin at all: a flag the spec does not know about
    # is one doctor's bounded model listing would not carry either.
    if grep -qE -- '(^| )--[a-z-]*(auto-?update|update)[a-z-]*( |$)' "$args_out"; then
      fail "$provider: undeclared update flag in argv (got: $recorded)"
    fi
    pass "$provider passes no update flag (its row declares none)"
  fi

  if [[ -n "$pin_env" ]]; then
    for assignment in $pin_env; do
      grep -qxF -- "$assignment" "$env_out" \
        || fail "$provider: provider environment is missing $assignment"
    done
    pass "$provider exports its update pin: $pin_env"
  fi
done

echo "ALL PROVIDER UPDATE-PIN TESTS PASSED"

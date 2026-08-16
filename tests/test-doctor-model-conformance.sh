#!/usr/bin/env bash
set -euo pipefail

# The probe grok-build would not have survived: doctor asks the INSTALLED CLI
# which models it serves and compares that inventory against every model this
# configuration would actually ask for. Covered here: a configured model absent
# from the listing blocks provider runs (fail + non-zero exit), the listing call
# is bounded/pinned/non-mutating, its result is cached per CLI version with a
# 24h TTL, a changed executable invalidates the cache, role overrides are
# checked and not just the default, and a CLI that will not answer produces
# "unverified" -- never a guessed pass.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
doctor_home="$tmp/home"
doctor_bin="$tmp/bin"
calls="$tmp/grok-calls.log"
mkdir -p "$repo/docs/orchestration/prompts" "$repo/schemas/orchestration" \
  "$doctor_home" "$doctor_bin"
for schema in "$ROOT"/schemas/*.schema.json; do
  cp "$schema" "$repo/schemas/orchestration/"
done
git -C "$tmp" init -q repo
git -C "$repo" config user.email doctor@example.com
git -C "$repo" config user.name doctor
printf 'lock\n' >"$repo/lockfile"
git -C "$repo" add lockfile
git -C "$repo" commit -qm init

# The mock speaks the real CLI's dialect: `grok --no-auto-update models` prints
# prose, a default line, then bulleted ids. Every argv it is handed is recorded,
# so the test can prove both the update pin and the cache.
cat >"$doctor_bin/grok" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$calls"
version="\${GROK_MOCK_VERSION:-1.0.4}"
case "\$*" in
  "--version") echo "grok \$version"; exit 0 ;;
  "--no-auto-update models")
    if [[ "\${GROK_MOCK_LISTING_BROKEN:-0}" == "1" ]]; then
      echo "Error: not logged in" >&2
      exit 1
    fi
    cat <<'LIST'
You are logged in with grok.com.

Default model: grok-4.6

Available models:
  * grok-4.6 (default)
  - grok-4.5
LIST
    exit 0 ;;
  "models") echo "unpinned listing must never run" >&2; exit 3 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$doctor_bin/grok"

write_config() {
  python3 - "$repo/singular.config.json" "$@" <<'PY'
import json, sys
path = sys.argv[1]
env = {"SINGULAR_GROK_MODEL": sys.argv[2]}
for pair in sys.argv[3:]:
    name, _, value = pair.partition("=")
    env[name] = value
data = {
    "schemaVersion": "v2",
    "targetBranch": "main",
    "gateCommand": "true",
    "runner": "grok-run.sh",
    "capabilityProfiles": {
        "audit-core": {
            "startup": "lazy",
            "strict": False,
            "required": ["filesystem", "git", "schemas", "runner-contract"],
            "optional": [],
        }
    },
    "roleProfiles": {"auditor": "audit-core", "decider": "audit-core"},
    "bootstrap": {
        "required": True,
        "lockfiles": ["lockfile"],
        "sharedStoreRoots": [],
        "sharedLinks": [],
    },
    "resources": {
        "diskReserveBytes": 0,
        "estimatedWorktreeBytes": 1024,
        "maxConcurrent": 2,
    },
    "env": env,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

doctor_json() {
  (
    cd "$repo"
    env HOME="$doctor_home" PATH="$doctor_bin:$PATH" \
      SINGULAR_ENGINE_HOME="$ROOT" XAI_API_KEY=test-key \
      "$@" bash "$ROOT/cli/singular" doctor --json
  )
}

check_field() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
report, check_id, expression = sys.argv[1:4]
data = json.loads(report)
by_id = {item["id"]: item for item in data["checks"]}
check = by_id.get(check_id)
assert check is not None, f"missing check {check_id}"
assert eval(expression, {"check": check, "report": data}), (check_id, check)
PY
}

listing_calls() {
  grep -c -- '--no-auto-update models' "$calls" 2>/dev/null || true
}

cache="$repo/.singular-state/doctor-cache/models-grok.json"

# 1. A model the installed CLI serves passes, and the probe leaves a cache
#    keyed to the executable it asked.
write_config grok-4.6
report="$(doctor_json)"
check_field "$report" model.availability 'check["status"] == "pass"'
check_field "$report" model.availability '"grok-4.6" in check["message"]'
check_field "$report" model.availability 'check["details"]["models"] == ["grok-4.5", "grok-4.6"]'
check_field "$report" model.availability '"provider-runs" in check["requiredFor"]'
[[ -f "$cache" ]] || { echo "probe must cache the listing" >&2; exit 1; }
python3 - "$cache" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema"] == "singular.doctor.model-listing.v0", data
assert data["models"] == ["grok-4.6", "grok-4.5"], data
assert data["cliKey"].endswith("@grok 1.0.4"), data
assert data["source"] == "grok --no-auto-update models", data
PY
[[ "$(listing_calls)" == "1" ]] \
  || { echo "expected exactly one listing call, got $(listing_calls)" >&2; exit 1; }

# The listing argv is pinned against provider self-update: an unpinned `models`
# would swap the executable the run is about to use, so the mock refuses it and
# only the pinned form may ever appear.
grep -q -- '^--no-auto-update models$' "$calls" \
  || { echo "listing must be update-pinned" >&2; exit 1; }
! grep -q -- '^models$' "$calls" \
  || { echo "unpinned listing was invoked" >&2; exit 1; }

# 2. Second run reads the cache: same executable, same version, inside the TTL.
report="$(doctor_json)"
check_field "$report" model.availability 'check["status"] == "pass"'
check_field "$report" model.availability 'check["details"]["cache"] == "hit"'
[[ "$(listing_calls)" == "1" ]] \
  || { echo "cached listing must not re-run the CLI" >&2; exit 1; }

# 3. grok-build, exactly as it shipped: right prefix, real-looking, never served.
#    This must FAIL and take the exit code with it -- required_for provider-runs
#    is what stops dispatch the way a dead runner does.
write_config grok-build
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "a nonexistent model must fail doctor" >&2; exit 1; }
check_field "$report" model.availability 'check["status"] == "fail"'
check_field "$report" model.availability '"provider-runs" in check["requiredFor"]'
check_field "$report" model.availability '"grok-build" in check["message"]'
check_field "$report" model.availability '"grok-4.6" in check["remediation"]'
check_field "$report" model.selection.grok 'check["status"] == "pass"'
python3 - "$report" <<'PY'
import json, sys
assert json.loads(sys.argv[1])["ok"] is False
PY

# 4. Role overrides are dispatched with, so they are checked too: a valid
#    default cannot vouch for an auditor override that names nothing.
write_config grok-4.6 SINGULAR_GROK_AUDITOR_MODEL=grok-9.9
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "a bad role override must fail doctor" >&2; exit 1; }
check_field "$report" model.availability 'check["status"] == "fail"'
check_field "$report" model.availability \
  'check["details"]["missing"] == {"SINGULAR_GROK_AUDITOR_MODEL": "grok-9.9"}'
check_field "$report" model.availability \
  '"SINGULAR_GROK_MODEL" in check["details"]["wanted"]'

# 5. A newly installed CLI is a different inventory: the cache is keyed by
#    version, so the probe re-runs instead of trusting the old listing.
write_config grok-4.6
before="$(listing_calls)"
report="$(GROK_MOCK_VERSION=2.0.0 doctor_json)"
check_field "$report" model.availability 'check["details"]["cache"] == "miss"'
[[ "$(listing_calls)" -gt "$before" ]] \
  || { echo "a new CLI version must re-probe" >&2; exit 1; }
python3 - "$cache" <<'PY'
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["cliKey"].endswith("@grok 2.0.0")
PY

# 6. A stale cache is not evidence. Age it past the 24h TTL and the probe runs.
python3 - "$cache" <<'PY'
import datetime as dt, json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
old = dt.datetime.now(dt.UTC) - dt.timedelta(hours=25)
data["fetchedAt"] = old.replace(microsecond=0).isoformat().replace("+00:00", "Z")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
before="$(listing_calls)"
report="$(doctor_json)"
check_field "$report" model.availability 'check["details"]["cache"] == "miss"'
[[ "$(listing_calls)" -gt "$before" ]] \
  || { echo "an expired cache must re-probe" >&2; exit 1; }

# 7. A CLI that will not answer yields "unverified", never a pass. The run
#    stays usable (warn, not fail): doctor did not prove the model wrong, it
#    proved nothing -- and saying nothing loudly is the whole point.
rm -rf "$repo/.singular-state/doctor-cache"
rc=0
report="$(GROK_MOCK_LISTING_BROKEN=1 doctor_json)" || rc=$?
[[ "$rc" -eq 0 ]] || { echo "an unreadable listing must not block runs" >&2; exit 1; }
check_field "$report" model.availability 'check["status"] == "warn"'
check_field "$report" model.availability '"unverified" in check["message"]'
[[ ! -f "$cache" ]] || { echo "a failed listing must not be cached" >&2; exit 1; }

# 8. A provider whose CLI has no listing at all is a fact about the provider,
#    not a defect on this host: info, with the same refusal to guess.
python3 - "$repo/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["runner"] = "claude-run.sh"
data["env"] = {"SINGULAR_CLAUDE_MODEL": "claude-opus-4-8"}
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
cat >"$doctor_bin/claude" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "--version") echo "claude 2.0.0"; exit 0 ;;
  "auth status") echo "Logged in"; exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$doctor_bin/claude"
report="$(doctor_json)"
check_field "$report" model.availability 'check["status"] == "skip"'
check_field "$report" model.availability '"no model listing" in check["message"]'

echo "PASS: test-doctor-model-conformance"

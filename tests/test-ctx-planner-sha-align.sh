#!/usr/bin/env bash
# Covers the SHA-alignment slice of the planner finalize wrapper in
# engine/ctx-planner-session.sh: singular_ctx_planner_session_finalize must store,
# in the finalized meta's existing promptSha256 field, the sha256 of the planner
# TEMPLATE file (docs/orchestration/prompts/l1-planner.md, honoring
# SINGULAR_PLANNER_TEMPLATE) — NOT the sha of the RENDERED per-frontier prompt its
# call site passes. This aligns both sides on the TEMPLATE sha so that a finalized
# planner meta round-trips through singular_planner_resume_decide (gate 8, which
# keys on the TEMPLATE sha) to `resume` instead of being permanently neutered to
# `fresh prompt-template-changed`.
#
# Asserts:
#   (a) rendered != template: finalizing with a rendered-prompt sha that differs
#       from the template sha still stores the TEMPLATE sha.
#   (b) SINGULAR_PLANNER_TEMPLATE override is honored (same canonical convention as
#       the decider's singular_planner_resume_template_path).
#   (c) finalize -> decide round-trips to `resume <sessionId>` with every other
#       gate satisfied.
#   (d) two-frontier proof: two finalizes for the same node using two DIFFERENT
#       rendered prompts but the SAME template both decide `resume`.
#   (e) fail-closed template: unreadable/absent template -> empty/absent stored
#       promptSha256 -> a later decide returns `fresh prompt-template-changed`,
#       never `resume`.
#   (f) feature-flag discipline: knob OFF / non-numeric-or-nonzero rc writes no
#       resumable meta.
#   (g) additive-schema discipline: the session-meta.v0 shape is reused unchanged
#       (only promptSha256's VALUE is normalized; node still set; no new fields).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_PS="$ENGINE_HOME/engine/ctx-planner-session.sh"
CTX_PR="$ENGINE_HOME/engine/ctx-planner-resume.sh"
REAL_TEMPLATE="$ENGINE_HOME/docs/orchestration/prompts/l1-planner.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
pass() { echo "ok: $*"; }

# --- Isolated state: never touch the real repo or its state dir --------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"
[[ -f "$CTX_PS" ]] || fail "engine not present yet: $CTX_PS"
# shellcheck disable=SC1090
source "$CTX_PS" || fail "sourcing $CTX_PS failed"
# shellcheck disable=SC1090
source "$CTX_PR" || fail "sourcing $CTX_PR failed"
[[ "$(type -t singular_ctx_planner_session_finalize)" == "function" ]] \
  || fail "singular_ctx_planner_session_finalize not defined by $CTX_PS"

NODE="planner-resume-gates"

# The planner template lives under SINGULAR_ROOT so the finalize wrapper (and the
# decider's template gate) resolve it via the default canonical path.
mkdir -p "$tmp/docs/orchestration/prompts"
[[ -f "$REAL_TEMPLATE" ]] || fail "missing planner template fixture source: $REAL_TEMPLATE"
cp "$REAL_TEMPLATE" "$tmp/docs/orchestration/prompts/l1-planner.md"
TPL_SHA="$(singular_sha256_file "$tmp/docs/orchestration/prompts/l1-planner.md")"
[[ -n "$TPL_SHA" ]] || fail "template sha came back empty"

# A rendered per-frontier prompt whose sha DIFFERS from the template by design.
render_a="$tmp/planner-prompt-A.md"
printf 'RENDERED frontier A: %s\n' "$(cat "$tmp/docs/orchestration/prompts/l1-planner.md")" > "$render_a"
RENDERED_A_SHA="$(singular_sha256_file "$render_a")"
[[ "$RENDERED_A_SHA" != "$TPL_SHA" ]] || fail "fixture bug: rendered A sha equals template sha"
render_b="$tmp/planner-prompt-B.md"
printf 'RENDERED frontier B (different!): %s\n' "$(cat "$tmp/docs/orchestration/prompts/l1-planner.md")" > "$render_b"
RENDERED_B_SHA="$(singular_sha256_file "$render_b")"
[[ "$RENDERED_B_SHA" != "$TPL_SHA" && "$RENDERED_B_SHA" != "$RENDERED_A_SHA" ]] \
  || fail "fixture bug: rendered B sha collides"

# A real worktree so the node-lineage gate (git merge-base --is-ancestor) runs.
wt="$tmp/worktree"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"

canon="$(singular_ctx_planner_session_path "$NODE")"

# Seed a runner-side provider meta so gates 3 (provider/sessionId) and 10 (cwd)
# are satisfied on the finalized meta, then finalize on top of it.
seed_provider() { # <session_id>
  singular_session_meta_write_provider "$canon" codex "$1" m e "$wt" 0
}

# ---------------------------------------------------------------------------
# (a) rendered != template: finalize stores the TEMPLATE sha, not the rendered.
# ---------------------------------------------------------------------------
export SINGULAR_PLANNER_SESSION=1
rm -f "$canon"; mkdir -p "$(dirname "$canon")"
seed_provider "SID-A"
singular_ctx_planner_session_finalize "$NODE" 0 "TASK-0010" "RUN-A" \
  "codex-run.sh" "$RENDERED_A_SHA" "$HEAD2" 1 \
  || fail "(a): finalize crashed"
[[ -f "$canon" ]] || fail "(a): no finalized meta at $canon"
STORED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("promptSha256",""))' "$canon")"
assert_eq "$STORED" "$TPL_SHA" "(a) stored promptSha256 is the TEMPLATE sha"
[[ "$STORED" != "$RENDERED_A_SHA" ]] || fail "(a): stored the RENDERED sha, not the template sha"
pass "(a) finalize normalizes promptSha256 to the template sha (not the rendered prompt sha)"

# ---------------------------------------------------------------------------
# (g) additive-schema discipline: shape unchanged; node set; no rogue fields.
# ---------------------------------------------------------------------------
python3 - "$canon" "$NODE" <<'PY' || fail "(g): finalized meta shape drifted"
import json, sys
path, node = sys.argv[1:3]
doc = json.load(open(path))
assert doc.get("schema") == "singular.orchestration.session-meta.v0", doc
assert doc.get("role") == "planner", doc
assert doc.get("node") == node, doc
assert doc.get("provider") == "codex" and doc.get("sessionId") == "SID-A", doc
allowed = {"schema","provider","sessionId","model","effort","cwd","exitCode",
           "createdAt","role","taskId","runId","runner","promptSha256",
           "headShaAtCreate","lastUsedAttempt","node"}
extra = set(doc) - allowed
assert not extra, f"unexpected new fields: {extra}"
print("schema-ok")
PY
pass "(g) session-meta.v0 shape reused unchanged; only promptSha256 value normalized; node still set"

# ---------------------------------------------------------------------------
# (b) SINGULAR_PLANNER_TEMPLATE override honored (same convention as the decider).
# ---------------------------------------------------------------------------
alt_tpl="$tmp/alt-template.md"
printf 'ALTERNATE planner template body\n' > "$alt_tpl"
ALT_SHA="$(singular_sha256_file "$alt_tpl")"
[[ "$ALT_SHA" != "$TPL_SHA" ]] || fail "fixture bug: alt template sha equals default"
rm -f "$canon"; seed_provider "SID-ALT"
SINGULAR_PLANNER_TEMPLATE="$alt_tpl" singular_ctx_planner_session_finalize "$NODE" 0 \
  "TASK-0010" "RUN-ALT" "codex-run.sh" "$RENDERED_A_SHA" "$HEAD2" 1 \
  || fail "(b): finalize crashed"
STORED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("promptSha256",""))' "$canon")"
assert_eq "$STORED" "$ALT_SHA" "(b) SINGULAR_PLANNER_TEMPLATE override drives the stored sha"
pass "(b) SINGULAR_PLANNER_TEMPLATE override honored (canonical template-path convention)"

# ---------------------------------------------------------------------------
# (c) finalize -> decide round-trips to resume with every other gate satisfied.
# ---------------------------------------------------------------------------
lease_path="$(singular_planner_resume_lease_path "$NODE")"; rm -f "$lease_path"
rm -f "$canon"; seed_provider "SID-RT"
singular_ctx_planner_session_finalize "$NODE" 0 "TASK-0010" "RUN-RT" \
  "codex-run.sh" "$RENDERED_A_SHA" "$HEAD2" 1 \
  || fail "(c): finalize crashed"
out="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$canon" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "resume SID-RT" "(c) finalize->decide round-trips to resume"
pass "(c) finalize under the knob -> decide yields resume <sessionId> (both sides align on template sha)"

# ---------------------------------------------------------------------------
# (d) two-frontier proof: two DIFFERENT rendered prompts, SAME template -> both
#     finalize to metas that each decide resume.
# ---------------------------------------------------------------------------
for pair in "SID-F1:$RENDERED_A_SHA" "SID-F2:$RENDERED_B_SHA"; do
  sid="${pair%%:*}"; rsha="${pair##*:}"
  rm -f "$canon" "$lease_path"; seed_provider "$sid"
  singular_ctx_planner_session_finalize "$NODE" 0 "TASK-0010" "RUN-$sid" \
    "codex-run.sh" "$rsha" "$HEAD2" 1 \
    || fail "(d): finalize crashed for $sid"
  out="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$canon" "$NODE" codex-run.sh "$wt" "$HEAD2")"
  assert_eq "$out" "resume $sid" "(d) frontier $sid decides resume"
done
pass "(d) two frontiers with different rendered prompts but the same template both decide resume"

# ---------------------------------------------------------------------------
# (e) fail-closed template: unreadable/absent template -> empty/absent stored
#     sha -> a later decide returns fresh prompt-template-changed (never resume).
# ---------------------------------------------------------------------------
missing_tpl="$tmp/nope/does-not-exist.md"
rm -f "$canon" "$lease_path"; seed_provider "SID-FAIL"
SINGULAR_PLANNER_TEMPLATE="$missing_tpl" singular_ctx_planner_session_finalize "$NODE" 0 \
  "TASK-0010" "RUN-FAIL" "codex-run.sh" "$RENDERED_A_SHA" "$HEAD2" 1 \
  || fail "(e): finalize crashed on absent template"
STORED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("promptSha256",""))' "$canon")"
[[ -z "$STORED" ]] || fail "(e): absent template stored a non-empty sha [$STORED] (must fail closed)"
[[ "$STORED" != "$RENDERED_A_SHA" ]] || fail "(e): fell back to the rendered sha"
# The decider (keyed on the REAL default template) must reject the empty sha.
out="$(SINGULAR_PLANNER_SESSION=1 singular_planner_resume_decide "$canon" "$NODE" codex-run.sh "$wt" "$HEAD2")"
assert_eq "$out" "fresh prompt-template-changed" "(e) empty stored sha -> fresh prompt-template-changed"
pass "(e) fail-closed template resolution: empty stored sha -> decide is fresh prompt-template-changed, never resume"

# ---------------------------------------------------------------------------
# (f) feature-flag discipline: knob OFF and non-numeric/non-zero rc write nothing.
# ---------------------------------------------------------------------------
rm -f "$canon"
unset SINGULAR_PLANNER_SESSION
singular_ctx_planner_session_finalize "$NODE" 0 "TASK-0010" "RUN-OFF" \
  "codex-run.sh" "$RENDERED_A_SHA" "$HEAD2" 1 || fail "(f): OFF finalize crashed"
[[ ! -e "$canon" ]] || fail "(f): meta written while knob OFF"
export SINGULAR_PLANNER_SESSION=1
rm -f "$canon"; seed_provider "SID-RC"
before="$(singular_sha256_file "$canon")"
singular_ctx_planner_session_finalize "$NODE" 1 "TASK-0010" "RUN-RC" \
  "codex-run.sh" "$RENDERED_A_SHA" "$HEAD2" 1 || fail "(f): rc!=0 finalize crashed"
# rc != 0 must not finalize a planner role onto the seeded meta.
role="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("role",""))' "$canon")"
[[ "$role" != "planner" ]] || fail "(f): a non-zero rc finalized a resumable planner meta"
rm -f "$canon"; seed_provider "SID-NAN"
singular_ctx_planner_session_finalize "$NODE" "notanumber" "TASK-0010" "RUN-NAN" \
  "codex-run.sh" "$RENDERED_A_SHA" "$HEAD2" 1 || fail "(f): non-numeric rc finalize crashed"
role="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("role",""))' "$canon")"
[[ "$role" != "planner" ]] || fail "(f): a non-numeric rc finalized a resumable planner meta"
pass "(f) feature-flag discipline: knob OFF / non-numeric / non-zero rc never finalizes a resumable meta"

echo "ctx-planner-sha-align tests passed"

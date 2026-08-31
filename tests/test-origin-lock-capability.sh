#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
git -C "$tmp" init -q repo
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
printf 'seed\n' >"$repo/seed.txt"
git -C "$repo" add seed.txt
git -C "$repo" commit -qm seed
git -C "$repo" branch -M integration
printf '{"schemaVersion":"v2","targetBranch":"integration","gateCommand":"true"}\n' \
  >"$repo/singular.config.json"

cd "$repo"
export SINGULAR_ENGINE_HOME="$ROOT"
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null
# shellcheck source=/dev/null
. "$ROOT/engine/lib.sh"
singular_ensure_state_dirs
singular_acquire_lock run-one

[[ "${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "origin lock capability was not generated" >&2; exit 1; }
[[ "$(singular_json_field "$SINGULAR_LOCK_FILE" capabilitySha256)" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "origin lock did not persist a capability digest" >&2; exit 1; }

# A Bash subshell inherits variables but has a distinct BASHPID. It must not
# be able to release the parent's origin lock with the copied capability.
if ( singular_release_lock run-one ); then
  echo "subshell released its parent's origin lock" >&2
  exit 1
fi
[[ -f "$SINGULAR_LOCK_FILE" && -d "$SINGULAR_LOCK_FILE.guard" ]] \
  || { echo "subshell damaged parent origin lock state" >&2; exit 1; }

# Only an explicitly authorized direct child receives the unforgeable token
# and may reuse the lock for the exact run. Public flags, wrong tokens, and
# wrong runs fail; ordinary children inherit no ambient authority.
singular_with_origin_lock_capability \
  bash -c '. "$1/engine/lib.sh"; singular_require_inherited_origin_lock run-one' \
    bash "$ROOT"
if env -u SINGULAR_ORIGIN_LOCK_CAPABILITY bash -c \
    '. "$1/engine/lib.sh"; singular_require_inherited_origin_lock run-one' \
    bash "$ROOT" >/dev/null 2>&1; then
  echo "missing inherited capability was accepted" >&2
  exit 1
fi
if SINGULAR_ORIGIN_LOCK_CAPABILITY=wrong bash -c \
    '. "$1/engine/lib.sh"; singular_require_inherited_origin_lock run-one' \
    bash "$ROOT" >/dev/null 2>&1; then
  echo "wrong inherited capability was accepted" >&2
  exit 1
fi
if singular_with_origin_lock_capability \
    bash -c '. "$1/engine/lib.sh"; singular_require_inherited_origin_lock other-run' \
      bash "$ROOT" >/dev/null 2>&1; then
  echo "inherited capability was accepted for a different run" >&2
  exit 1
fi
if env -u SINGULAR_ORIGIN_LOCK_CAPABILITY \
    bash "$ROOT/engine/integrate.sh" --from-reconcile --run-id run-one --dry-run \
    >"$tmp/forged-integrate.log" 2>&1; then
  echo "integrate accepted a caller-forged --from-reconcile flag" >&2
  exit 1
fi
grep -q 'verified inherited lock authority' "$tmp/forged-integrate.log" \
  || { cat "$tmp/forged-integrate.log" >&2; exit 1; }
if env -u SINGULAR_ORIGIN_LOCK_CAPABILITY \
    bash "$ROOT/engine/promote-gate.sh" --from-reconcile --frontier \
    >"$tmp/forged-promoter.log" 2>&1; then
  echo "promoter accepted a caller-forged --from-reconcile flag" >&2
  exit 1
fi
grep -q 'verified inherited lock authority' "$tmp/forged-promoter.log" \
  || { cat "$tmp/forged-promoter.log" >&2; exit 1; }
if env -u SINGULAR_ORIGIN_LOCK_CAPABILITY \
    bash "$ROOT/engine/ops.sh" gc --from-reconcile run-one \
    >"$tmp/forged-gc.log" 2>&1; then
  echo "gc accepted a caller-forged --from-reconcile flag" >&2
  exit 1
fi
grep -q 'lock capability did not verify' "$tmp/forged-gc.log" \
  || { cat "$tmp/forged-gc.log" >&2; exit 1; }

# A genuine inherited invocation does not contend with or release its parent's
# lock, even when there is no accepted work to integrate.
singular_with_origin_lock_capability \
  bash "$ROOT/engine/integrate.sh" --from-reconcile --run-id run-one --dry-run \
    >/dev/null
[[ -f "$SINGULAR_LOCK_FILE" ]] || { echo "child released parent origin lock" >&2; exit 1; }

singular_release_lock run-one
[[ ! -e "$SINGULAR_LOCK_FILE" ]] || { echo "origin lock was not released" >&2; exit 1; }
[[ -z "${SINGULAR_ORIGIN_LOCK_CAPABILITY:-}" ]] \
  || { echo "released origin lock retained its capability" >&2; exit 1; }

# Campaign publication locks have the same process-and-generation ownership
# rule. A copied token alone is not release authority.
singular_campaign_lock_acquire
campaign_lock_path="$(singular_campaign_lock_path)"
if ( singular_campaign_lock_release ); then
  echo "subshell released its parent's campaign lock" >&2
  exit 1
fi
[[ -d "$campaign_lock_path" ]] \
  || { echo "subshell damaged parent campaign lock state" >&2; exit 1; }
singular_campaign_lock_release
[[ ! -e "$campaign_lock_path" ]] \
  || { echo "campaign lock was not released" >&2; exit 1; }

# Git operation locks also require both the owning process and the random
# per-acquisition capability. A Bash subshell inherits the token but has a
# distinct BASHPID and therefore cannot release its parent's lock.
singular_git_lock_acquire
git_lock_path="$(singular_git_lock_path)"
[[ "${SINGULAR_GIT_LOCK_CAPABILITY:-}" =~ ^[0-9a-f]{32}$ ]] \
  || { echo "git lock capability was not generated" >&2; exit 1; }
if ( singular_git_lock_release ); then
  echo "subshell released its parent's git operation lock" >&2
  exit 1
fi
[[ -d "$git_lock_path" ]] \
  || { echo "subshell damaged parent git operation lock state" >&2; exit 1; }
singular_git_lock_release
[[ ! -e "$git_lock_path" ]] \
  || { echo "git operation lock was not released" >&2; exit 1; }

# Stale recovery must fail closed when the campaign lock pathname is a symlink.
# In particular, owner.json and pid are attacker-controlled names below the
# symlink target: recovery must not follow the moved symlink and unlink them.
campaign_external="$tmp/external-campaign-lock"
mkdir -p "$campaign_external"
printf '{"pid":999999999,"token":"external-owner-sentinel"}\n' \
  >"$campaign_external/owner.json"
printf '999999999\n' >"$campaign_external/pid"
printf 'keep-campaign-sentinel\n' >"$campaign_external/keep.txt"
campaign_owner_before="$(shasum -a 256 "$campaign_external/owner.json" | awk '{print $1}')"
campaign_pid_before="$(shasum -a 256 "$campaign_external/pid" | awk '{print $1}')"
campaign_keep_before="$(shasum -a 256 "$campaign_external/keep.txt" | awk '{print $1}')"
ln -s "$campaign_external" "$campaign_lock_path"
campaign_symlink_rc=0
SINGULAR_CAMPAIGN_LOCK_WAIT_TICKS=2 \
  singular_campaign_lock_acquire >"$tmp/campaign-symlink.log" 2>&1 \
  || campaign_symlink_rc=$?
if [[ "$campaign_symlink_rc" -eq 0 ]]; then
  singular_campaign_lock_release 2>/dev/null || true
fi
[[ -f "$campaign_external/owner.json" && -f "$campaign_external/pid" \
    && -f "$campaign_external/keep.txt" ]] \
  || { echo "campaign stale recovery deleted an external sentinel" >&2; exit 1; }
[[ "$(shasum -a 256 "$campaign_external/owner.json" | awk '{print $1}')" == "$campaign_owner_before" \
    && "$(shasum -a 256 "$campaign_external/pid" | awk '{print $1}')" == "$campaign_pid_before" \
    && "$(shasum -a 256 "$campaign_external/keep.txt" | awk '{print $1}')" == "$campaign_keep_before" ]] \
  || { echo "campaign stale recovery mutated an external sentinel" >&2; exit 1; }
[[ "$campaign_symlink_rc" -ne 0 ]] \
  || { echo "campaign lock accepted a symlink lock directory" >&2; exit 1; }
[[ -L "$campaign_lock_path" ]] \
  || { echo "campaign stale recovery replaced the attacker symlink" >&2; exit 1; }
rm "$campaign_lock_path"

# The origin guard uses the same stale-directory recovery shape. A symlinked
# guard must be rejected without reading through it as ownership authority or
# deleting the target's pid sentinel.
origin_guard_path="$SINGULAR_LOCK_FILE.guard"
origin_external="$tmp/external-origin-guard"
mkdir -p "$origin_external"
printf '999999999\n' >"$origin_external/pid"
printf 'keep-origin-sentinel\n' >"$origin_external/keep.txt"
origin_pid_before="$(shasum -a 256 "$origin_external/pid" | awk '{print $1}')"
origin_keep_before="$(shasum -a 256 "$origin_external/keep.txt" | awk '{print $1}')"
ln -s "$origin_external" "$origin_guard_path"
origin_symlink_rc=0
singular_acquire_lock symlink-run >"$tmp/origin-symlink.log" 2>&1 \
  || origin_symlink_rc=$?
if [[ "$origin_symlink_rc" -eq 0 ]]; then
  singular_release_lock symlink-run 2>/dev/null || true
fi
[[ -f "$origin_external/pid" && -f "$origin_external/keep.txt" ]] \
  || { echo "origin stale recovery deleted an external sentinel" >&2; exit 1; }
[[ "$(shasum -a 256 "$origin_external/pid" | awk '{print $1}')" == "$origin_pid_before" \
    && "$(shasum -a 256 "$origin_external/keep.txt" | awk '{print $1}')" == "$origin_keep_before" ]] \
  || { echo "origin stale recovery mutated an external sentinel" >&2; exit 1; }
[[ "$origin_symlink_rc" -ne 0 ]] \
  || { echo "origin lock accepted a symlink guard directory" >&2; exit 1; }
[[ -L "$origin_guard_path" ]] \
  || { echo "origin stale recovery replaced the attacker symlink" >&2; exit 1; }
rm "$origin_guard_path"

# Deterministically pause an old recoverer after it has atomically quarantined
# a stale guard but before it removes that quarantine. A new process can then
# acquire the now-free canonical guard and publish fresh metadata. Resuming the
# old recoverer must never move or delete that new generation's metadata, and
# the new owner must retain enough authority to release normally.
mkdir "$origin_guard_path"
printf '999999999\n' >"$origin_guard_path/pid"
old_quarantined="$tmp/origin-old-quarantined"
old_continue="$tmp/origin-old-continue"
old_rc_file="$tmp/origin-old.rc"
new_ready="$tmp/origin-new-ready"
new_release="$tmp/origin-new-release"
new_acquire_rc_file="$tmp/origin-new-acquire.rc"
new_release_rc_file="$tmp/origin-new-release.rc"

env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" \
  SINGULAR_ENGINE_HOME="$ROOT" \
  SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
  OLD_QUARANTINED="$old_quarantined" \
  OLD_CONTINUE="$old_continue" \
  OLD_RC_FILE="$old_rc_file" \
  bash -c '
    . "$SINGULAR_ENGINE_HOME/engine/lib.sh"
    singular_origin_guard_remove_stale() {
      local stale_path="$1"
      : >"$OLD_QUARANTINED"
      while [[ ! -e "$OLD_CONTINUE" ]]; do sleep 0.01; done
      rm -rf -- "$stale_path"
    }
    set +e
    singular_acquire_lock old-recoverer
    rc=$?
    set -e
    printf "%s\n" "$rc" >"$OLD_RC_FILE"
    if [[ "$rc" -eq 0 ]]; then
      singular_release_lock old-recoverer || true
    fi
  ' >"$tmp/origin-old.log" 2>&1 &
old_recoverer_pid=$!

for _ in $(seq 1 300); do
  [[ -e "$old_quarantined" ]] && break
  sleep 0.01
done
[[ -e "$old_quarantined" ]] \
  || { echo "old origin recoverer did not quarantine the stale guard" >&2; exit 1; }
[[ ! -e "$origin_guard_path" ]] \
  || { echo "canonical origin guard remained occupied after quarantine" >&2; exit 1; }

env \
  SINGULAR_ROOT="$repo" \
  SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" \
  SINGULAR_ENGINE_HOME="$ROOT" \
  SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
  NEW_READY="$new_ready" \
  NEW_RELEASE="$new_release" \
  NEW_ACQUIRE_RC_FILE="$new_acquire_rc_file" \
  NEW_RELEASE_RC_FILE="$new_release_rc_file" \
  bash -c '
    . "$SINGULAR_ENGINE_HOME/engine/lib.sh"
    set +e
    singular_acquire_lock new-owner
    acquire_rc=$?
    set -e
    printf "%s\n" "$acquire_rc" >"$NEW_ACQUIRE_RC_FILE"
    [[ "$acquire_rc" -eq 0 ]] || exit "$acquire_rc"
    : >"$NEW_READY"
    while [[ ! -e "$NEW_RELEASE" ]]; do sleep 0.01; done
    set +e
    singular_release_lock new-owner
    release_rc=$?
    set -e
    printf "%s\n" "$release_rc" >"$NEW_RELEASE_RC_FILE"
    exit "$release_rc"
  ' >"$tmp/origin-new.log" 2>&1 &
new_owner_pid=$!

for _ in $(seq 1 300); do
  [[ -e "$new_ready" ]] && break
  sleep 0.01
done
[[ -e "$new_ready" ]] || {
  : >"$old_continue"
  wait "$old_recoverer_pid" 2>/dev/null || true
  cat "$tmp/origin-new.log" >&2
  echo "new origin owner did not acquire after stale guard quarantine" >&2
  exit 1
}
[[ "$(cat "$new_acquire_rc_file")" == 0 ]] \
  || { echo "new origin owner acquisition failed" >&2; exit 1; }
new_metadata_sha="$(shasum -a 256 "$SINGULAR_LOCK_FILE" | awk '{print $1}')"
[[ "$(singular_json_field "$SINGULAR_LOCK_FILE" runId)" == new-owner ]] \
  || { echo "new origin owner did not publish its metadata generation" >&2; exit 1; }

: >"$old_continue"
wait "$old_recoverer_pid" || true
origin_interleaving_failures=0
if [[ ! -f "$old_rc_file" || "$(cat "$old_rc_file")" != 75 ]]; then
  echo "old origin recoverer did not defer to the live replacement owner" >&2
  origin_interleaving_failures=$((origin_interleaving_failures + 1))
fi
if [[ ! -f "$SINGULAR_LOCK_FILE" ]]; then
  echo "old origin recoverer moved or deleted the new owner's metadata" >&2
  origin_interleaving_failures=$((origin_interleaving_failures + 1))
elif [[ "$(shasum -a 256 "$SINGULAR_LOCK_FILE" | awk '{print $1}')" \
    != "$new_metadata_sha" ]]; then
  echo "old origin recoverer mutated the new owner's metadata" >&2
  origin_interleaving_failures=$((origin_interleaving_failures + 1))
fi

: >"$new_release"
wait "$new_owner_pid" || true
if [[ ! -f "$new_release_rc_file" || "$(cat "$new_release_rc_file")" != 0 ]]; then
  echo "new origin owner could not release after stale recovery interleaving" >&2
  origin_interleaving_failures=$((origin_interleaving_failures + 1))
fi
if [[ -e "$SINGULAR_LOCK_FILE" || -e "$origin_guard_path" ]]; then
  echo "origin stale recovery interleaving left canonical lock state behind" >&2
  origin_interleaving_failures=$((origin_interleaving_failures + 1))
fi
if [[ "$origin_interleaving_failures" -ne 0 ]]; then
  cat "$tmp/origin-old.log" >&2
  cat "$tmp/origin-new.log" >&2
  echo "$origin_interleaving_failures origin stale-recovery interleaving assertion(s) failed" >&2
  exit 1
fi

# Refuse a rebound/broad cleanup target before creating or deleting anything.
expected_git_lock_dir="$SINGULAR_GIT_LOCK_DIR"
SINGULAR_GIT_LOCK_DIR="$tmp/outside-git-op.lock"
if singular_git_lock_acquire >"$tmp/unsafe-git-lock.log" 2>&1; then
  echo "unsafe git operation lock path was accepted" >&2
  exit 1
fi
grep -q 'unsafe git operation lock path' "$tmp/unsafe-git-lock.log" \
  || { cat "$tmp/unsafe-git-lock.log" >&2; exit 1; }
[[ ! -e "$SINGULAR_GIT_LOCK_DIR" ]] \
  || { echo "unsafe git operation lock path was mutated" >&2; exit 1; }
SINGULAR_GIT_LOCK_DIR="$expected_git_lock_dir"

# The public and mirrored lock schemas must accept the same metadata surface.
python3 - "$ROOT/schemas/lock.v0.schema.json" \
  "$ROOT/schemas/orchestration/lock.v0.schema.json" <<'PY'
import json
import sys
left, right = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:3])
assert left["properties"] == right["properties"]
assert left["required"] == right["required"]
PY

# Acquisition itself is atomic: synchronized contenders may not both win.
winners="$tmp/race-winners"
start="$tmp/race-start"
: >"$winners"
for contender in a b; do
  (
    while [[ ! -e "$start" ]]; do sleep 0.01; done
    if bash -c '
      . "$1/engine/lib.sh"
      if singular_acquire_lock "$2"; then
        printf "%s\n" "$2" >>"$3"
        sleep 1
        singular_release_lock "$2"
        exit 0
      fi
      exit 75
    ' bash "$ROOT" "race-$contender" "$winners"; then
      :
    fi
  ) &
done
: >"$start"
wait
[[ "$(wc -l <"$winners" | tr -d '[:space:]')" == "1" ]] \
  || { echo "origin lock race produced multiple winners" >&2; cat "$winners" >&2; exit 1; }
[[ ! -e "$SINGULAR_LOCK_FILE" && ! -e "$SINGULAR_LOCK_FILE.guard" ]] \
  || { echo "origin lock race left lock state behind" >&2; exit 1; }

# With a deliberately short wait budget and a long owner hold, synchronized
# campaign-lock contenders yield one owner and one timeout, never two owners.
campaign_winners="$tmp/campaign-race-winners"
campaign_start="$tmp/campaign-race-start"
: >"$campaign_winners"
for contender in a b; do
  (
    while [[ ! -e "$campaign_start" ]]; do sleep 0.01; done
    SINGULAR_CAMPAIGN_LOCK_WAIT_TICKS=2 bash -c '
      . "$1/engine/lib.sh"
      if singular_campaign_lock_acquire; then
        printf "%s\n" "$2" >>"$3"
        sleep 1
        singular_campaign_lock_release
        exit 0
      fi
      exit 75
    ' bash "$ROOT" "campaign-$contender" "$campaign_winners" || true
  ) &
done
: >"$campaign_start"
wait
[[ "$(wc -l <"$campaign_winners" | tr -d '[:space:]')" == "1" ]] \
  || { echo "campaign lock race produced multiple winners" >&2; cat "$campaign_winners" >&2; exit 1; }
[[ ! -e "$(singular_campaign_lock_path)" ]] \
  || { echo "campaign lock race left lock state behind" >&2; exit 1; }

# With the same short wait budget, synchronized git-lock contenders produce
# one owner and one timeout. They can never overlap in the critical section.
git_winners="$tmp/git-race-winners"
git_start="$tmp/git-race-start"
: >"$git_winners"
for contender in a b; do
  (
    while [[ ! -e "$git_start" ]]; do sleep 0.01; done
    SINGULAR_GIT_LOCK_WAIT_TICKS=2 bash -c '
      . "$1/engine/lib.sh"
      if singular_git_lock_acquire; then
        printf "%s\n" "$2" >>"$3"
        sleep 1
        singular_git_lock_release
        exit 0
      fi
      exit 75
    ' bash "$ROOT" "git-$contender" "$git_winners" || true
  ) &
done
: >"$git_start"
wait
[[ "$(wc -l <"$git_winners" | tr -d '[:space:]')" == "1" ]] \
  || { echo "git operation lock race produced multiple winners" >&2; cat "$git_winners" >&2; exit 1; }
[[ ! -e "$(singular_git_lock_path)" ]] \
  || { echo "git operation lock race left lock state behind" >&2; exit 1; }

# A SIGKILL cannot run the holder's cleanup. The next owner must detect the
# dead PID, atomically quarantine the directory, remove only that validated
# stale path, and acquire a fresh capability generation.
git_holder_ready="$tmp/git-holder-ready"
bash -c '
  . "$1/engine/lib.sh"
  singular_git_lock_acquire
  printf "%s\n" "${BASHPID:-$$}" >"$2"
  while :; do sleep 1; done
' bash "$ROOT" "$git_holder_ready" &
git_holder_pid=$!
for _ in $(seq 1 200); do
  [[ -s "$git_holder_ready" ]] && break
  sleep 0.01
done
[[ -s "$git_holder_ready" && -d "$(singular_git_lock_path)" ]] \
  || { echo "git operation lock holder did not become ready" >&2; exit 1; }
dead_holder_capability="$(singular_json_field \
  "$(singular_git_lock_path)/owner.json" token)"
kill -KILL "$git_holder_pid"
wait "$git_holder_pid" 2>/dev/null || true

SINGULAR_GIT_LOCK_WAIT_TICKS=20 singular_git_lock_acquire
[[ "${SINGULAR_GIT_LOCK_CAPABILITY:-}" =~ ^[0-9a-f]{32}$ ]] \
  || { echo "stale git lock recovery did not mint a capability" >&2; exit 1; }
[[ "$SINGULAR_GIT_LOCK_CAPABILITY" != "$dead_holder_capability" ]] \
  || { echo "stale git lock recovery reused the dead capability" >&2; exit 1; }
singular_git_lock_release
[[ ! -e "$(singular_git_lock_path)" ]] \
  || { echo "stale git operation lock recovery left the live lock behind" >&2; exit 1; }
if find "$(dirname "$(singular_git_lock_path)")" -maxdepth 1 \
    -name 'git-op.lock.stale.*' -print -quit | grep -q .; then
  echo "stale git operation lock recovery left quarantine state behind" >&2
  exit 1
fi

echo "PASS origin lock capability"

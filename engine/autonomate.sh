#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${GLUERUN_BASH_BIN:-}" ]]; then
    [[ "$GLUERUN_BASH_BIN" == /* && -x "$GLUERUN_BASH_BIN" ]] || { echo "invalid GLUERUN_BASH_BIN: $GLUERUN_BASH_BIN" >&2; exit 2; }
    exec "$GLUERUN_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "autonomate.sh requires bash >= 4" >&2; exit 1
fi

# The self-driving loop. Each iteration runs one full actuate cycle (import ->
# recover -> generate a ready frontier if idle -> dispatch worker batch -> audit
# -> auto-fix -> integrate -> push), then writes STATUS and sleeps. It stops on: the STOP
# sentinel, the wall-clock budget (GLUERUN_MAX_HOURS), the circuit breaker
# (GLUERUN_MAX_CONSEC_FAILS consecutive no-progress failures), or DAG exhaustion.
#
# Single-instance via a pidfile so the launchd watchdog only relaunches it if it
# died. `--once` runs a single iteration (for tests).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
reconcile_script="${GLUERUN_RECONCILE_SCRIPT:-$SCRIPT_DIR/reconcile.sh}"

export GLUERUN_TARGET_BRANCH="${GLUERUN_TARGET_BRANCH:-}"
export GLUERUN_AUTO_INTEGRATE="${GLUERUN_AUTO_INTEGRATE:-1}"
export GLUERUN_PUSH="${GLUERUN_PUSH:-1}"
export GLUERUN_GENERATE="${GLUERUN_GENERATE:-1}"
sleep_secs="${GLUERUN_SLEEP:-20}"
quota_sleep_cap="${GLUERUN_QUOTA_SLEEP_CAP:-300}"       # max seconds per quota-window poll nap
quota_wait_budget="${GLUERUN_QUOTA_WAIT_BUDGET:-10800}" # total quota-wait before escalating to STOP (3h)
quota_waited_total=0
# Provider overload gets its own budget. Sharing one would let a burst of 529s
# spend the usage-limit budget and escalate to STOP for a reason that was never
# a usage limit.
overload_wait_budget="${GLUERUN_OVERLOAD_WAIT_BUDGET:-3600}"
overload_waited_total=0
once="no"
detach="no"
for arg in "$@"; do
  case "$arg" in
    --once) once="yes" ;;
    --detach) detach="yes" ;;
    *) echo "autonomate: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

gluerun_ensure_state_dirs
gluerun_require_target_branch

pidfile="$GLUERUN_STATE_DIR/autonomate.pid"
# The process identity lives BESIDE the pidfile, not inside it. ops.sh, doctor
# and the console all read the pidfile with `cat` and expect a bare number;
# adding a second line to it broke `gluerun auto --detach` outright and would
# have broken five more readers quietly.
pididfile="$pidfile.identity"
pid_start_of() { ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//;s/ *$//'; }

# True when the pidfile names a process that is genuinely still this loop.
#
# `kill -0` alone cannot: a pid is a small recycled integer, and an unrelated
# long-running process that inherits the number reads as "autonomate is already
# running" forever, with no way to start the loop again short of deleting the
# file by hand. Recording `ps lstart` at claim time and comparing it here is what
# tells the two apart.
autonomate_holder_alive() {
  local holder_pid holder_start
  holder_pid="$(sed -n '1p' "$pidfile" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$holder_pid" ]] || return 1
  kill -0 "$holder_pid" 2>/dev/null || return 1
  holder_start="$(sed -n '1p' "$pididfile" 2>/dev/null)"
  # No recorded identity: a pidfile written by an older engine. Trust the pid,
  # since refusing to start is the safer of the two wrong answers there.
  [[ -n "$holder_start" ]] || return 0
  [[ "$holder_start" == "$(pid_start_of "$holder_pid")" ]]
}

# --detach (0.5.0): supported daemonized launch. The field run hand-rolled
# python setsid double-forks 6+ times because plain `nohup ... &` dies on
# shell handoff and launchd is TCC-blocked on user dirs. The child re-execs
# this script with GLUERUN_AUTONOMATE_DETACHED=1; the parent waits for the
# pidfile to prove liveness, prints it, and exits.
if [[ "$detach" == "yes" && "${GLUERUN_AUTONOMATE_DETACHED:-}" != "1" ]]; then
  # Identity-aware, like the claim below. This check used to be `kill -0` alone,
  # so a recycled pid made `gluerun auto --detach` a permanent no-op.
  if autonomate_holder_alive; then
    echo "autonomate already running (pid $(sed -n '1p' "$pidfile" 2>/dev/null))"
    exit 0
  fi
  detach_log="$GLUERUN_STATE_DIR/autonomate.log"
  detach_args=()
  [[ "$once" == "yes" ]] && detach_args+=("--once")
  GLUERUN_AUTONOMATE_DETACHED=1 python3 - "$BASH_SOURCE" "$detach_log" \
    "$(gluerun_bash_bin)" ${detach_args[@]+"${detach_args[@]}"} <<'PY'
import os, sys
script, log, bash_bin = sys.argv[1:4]
extra = sys.argv[4:]
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        devnull = os.open(os.devnull, os.O_RDONLY)
        os.dup2(devnull, 0)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.execv(bash_bin, [bash_bin, script] + extra)
    os._exit(0)
os.wait()
PY
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    newpid="$(sed -n '1p' "$pidfile" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$newpid" && "$newpid" != "$$" ]] && kill -0 "$newpid" 2>/dev/null; then
      echo "autonomate: detached pid=$newpid log=$detach_log"
      exit 0
    fi
  done
  echo "autonomate: detached launch FAILED; last log lines:" >&2
  tail -5 "$detach_log" 2>/dev/null >&2 || true
  exit 1
fi
# Single-instance guard.
#
# This used to read the pidfile, decide, and then write it — two processes
# racing that window both saw a dead predecessor and both started. The habitual
# `breaker reset; wake; auto` recovery sequence sits right on top of it: `wake`
# drops STOP while the previous loop is still exiting, and `auto` follows within
# a second.
#
# mkdir is the atomic primitive (the same one gluerun_git_lock_acquire uses):
# exactly one process can create the directory, so exactly one can claim the
# pidfile. Liveness is decided by autonomate_holder_alive above, which is
# pid-reuse-safe.
pidlock="$pidfile.lock"

autonomate_write_pidfile() {
  printf '%s\n' "$$" >"$pidfile"
  printf '%s\n' "$(pid_start_of $$)" >"$pididfile"
}

autonomate_claim_pidfile() {
  if mkdir "$pidlock" 2>/dev/null; then
    if autonomate_holder_alive; then
      rmdir "$pidlock" 2>/dev/null || true
      return 1
    fi
    autonomate_write_pidfile
    rmdir "$pidlock" 2>/dev/null || true
    return 0
  fi
  # Another process holds the lock right now; give it a moment to finish
  # writing, then defer to it.
  local waited=0
  while [[ -d "$pidlock" && "$waited" -lt 50 ]]; do sleep 0.1; waited=$((waited + 1)); done
  autonomate_holder_alive && return 1
  if mkdir "$pidlock" 2>/dev/null; then
    autonomate_write_pidfile
    rmdir "$pidlock" 2>/dev/null || true
    return 0
  fi
  return 1
}

if ! autonomate_claim_pidfile; then
  echo "autonomate already running (pid $(sed -n '1p' "$pidfile" 2>/dev/null)); exiting"
  exit 0
fi
cleanup() {
  if [[ "$(sed -n '1p' "$pidfile" 2>/dev/null | tr -d '[:space:]')" == "$$" ]]; then
    rm -f "$pidfile" "$pididfile"
  fi
  rmdir "$pidlock" 2>/dev/null || true
}
trap cleanup EXIT

start_ts="$(date +%s)"
max_hours_int="${GLUERUN_MAX_HOURS%%.*}"; [[ "$max_hours_int" =~ ^[0-9]+$ ]] || max_hours_int=20
deadline=$(( start_ts + max_hours_int * 3600 ))
gluerun_breaker_reset
iteration=0

gluerun_append_event "autonomate.started" "autonomous loop started" \
  "{\"pid\":$$,\"maxHours\":\"$GLUERUN_MAX_HOURS\",\"autoIntegrate\":\"$GLUERUN_AUTO_INTEGRATE\",\"push\":\"$GLUERUN_PUSH\"}"

while true; do
  iteration=$((iteration + 1))
  now="$(date +%s)"

  if gluerun_stop_requested; then
    echo "[autonomate] STOP sentinel; halting after $((iteration-1)) iteration(s)"
    gluerun_write_status "$iteration" "stopped (STOP sentinel)"
    gluerun_append_event "autonomate.stopped" "stopped by STOP sentinel" "{\"iteration\":$iteration}"
    break
  fi
  if [[ "$now" -ge "$deadline" ]]; then
    echo "[autonomate] wall-clock budget reached (${GLUERUN_MAX_HOURS}h); halting"
    gluerun_write_status "$iteration" "stopped (time-box ${GLUERUN_MAX_HOURS}h)"
    gluerun_append_event "autonomate.stopped" "stopped by time-box" "{\"iteration\":$iteration}"
    break
  fi
  breaker="$(gluerun_breaker_count)"
  if [[ "$breaker" -ge "$GLUERUN_MAX_CONSEC_FAILS" ]]; then
    echo "[autonomate] circuit breaker open ($breaker/$GLUERUN_MAX_CONSEC_FAILS); halting"
    gluerun_write_status "$iteration" "stopped (circuit breaker $breaker/$GLUERUN_MAX_CONSEC_FAILS)"
    gluerun_append_event "autonomate.stopped" "stopped by circuit breaker" "{\"iteration\":$iteration,\"consecFails\":$breaker}"
    break
  fi

  # Provider window: a planner backoff whose failureClass names one means the
  # provider — not the code — is refusing. Two classes qualify:
  #
  #   quota                the session *usage limit* (or an entitlement denial)
  #   provider-overloaded  a 503/529: the provider shedding load
  #
  # Refusing to plan is correct in both cases, but neither is a code failure and
  # neither may trip the circuit breaker; the loop sleeps through the window so
  # it auto-recovers. They differ only in how long: a usage limit is tens of
  # minutes, an overload is seconds, and each carries its own wait budget.
  # EVERY other failure class falls through to the normal cycle below and still
  # counts toward the breaker. STOP is honored before and after the nap, and the
  # wait budget escalates an unbounded window to STOP rather than idling forever.
  # With no active backoff this block is a no-op.
  planner_backoff_at_cycle_start=0
  bo_json="$(gluerun_planner_backoff_active_json 2>/dev/null || true)"
  if [[ -n "$bo_json" ]]; then
    planner_backoff_at_cycle_start=1
    bo_class=""; bo_remaining=0
    read -r bo_class bo_remaining < <(python3 - "$bo_json" <<'PY'
import json, sys
from datetime import datetime, timezone
try:
    d = json.loads(sys.argv[1])
    rem = int((datetime.fromisoformat(str(d.get("until", "")).replace("Z", "+00:00")) - datetime.now(timezone.utc)).total_seconds())
    if rem < 0:
        rem = 0
    print(d.get("failureClass", "unknown"), rem)
except Exception:
    print("unknown", 0)
PY
)
    [[ "$bo_remaining" =~ ^[0-9]+$ ]] || bo_remaining=0
    if [[ ( "$bo_class" == "quota" || "$bo_class" == "provider-overloaded" ) && "$bo_remaining" -gt 0 ]]; then
      if [[ "$bo_class" == "provider-overloaded" ]]; then
        window_label="provider overload"; window_waited="$overload_waited_total"; window_budget="$overload_wait_budget"
      else
        window_label="quota"; window_waited="$quota_waited_total"; window_budget="$quota_wait_budget"
      fi
      if [[ "$window_waited" -ge "$window_budget" ]]; then
        echo "[autonomate] $window_label wait budget exhausted (${window_waited}s >= ${window_budget}s); setting STOP"
        : >"$GLUERUN_STOP_FILE"
        gluerun_write_status "$iteration" "stopped ($window_label wait budget ${window_budget}s exhausted)"
        gluerun_append_event "autonomate.stopped" "stopped: $window_label wait budget exhausted" "{\"iteration\":$iteration,\"failureClass\":\"$bo_class\",\"waitedTotal\":$window_waited}"
        break
      fi
      nap="$bo_remaining"; [[ "$nap" -gt "$quota_sleep_cap" ]] && nap="$quota_sleep_cap"
      echo "[autonomate] planner $window_label window open (${bo_remaining}s left); sleeping up to ${nap}s WITHOUT breaker increment (waited ${window_waited}s)"
      gluerun_append_event "autonomate.quota_wait" "sleeping through planner $window_label window" "{\"iteration\":$iteration,\"failureClass\":\"$bo_class\",\"remainingSec\":$bo_remaining,\"napSec\":$nap,\"waitedTotal\":$window_waited}"
      gluerun_write_status "$iteration" "sleeping through $window_label window (${bo_remaining}s left, waited ${window_waited}s)"
      [[ "$once" == "yes" ]] && { echo "[autonomate] --once: $window_label wait detected, single iteration done"; break; }
      # Interruptible (0.5.0): STOP mid-nap ends the loop within
      # GLUERUN_SLEEP_POLL_SEC; `gluerun wake` / clear-backoff end the nap
      # early. Only actually-slept seconds count toward the window's budget.
      nap_started=$SECONDS
      nap_rc=0
      gluerun_interruptible_sleep "$nap" 1 || nap_rc=$?
      if [[ "$bo_class" == "provider-overloaded" ]]; then
        overload_waited_total=$((overload_waited_total + SECONDS - nap_started))
      else
        quota_waited_total=$((quota_waited_total + SECONDS - nap_started))
      fi
      [[ "$nap_rc" -eq 2 ]] && { echo "[autonomate] STOP during $window_label wait; halting"; break; }
      gluerun_stop_requested && { echo "[autonomate] STOP during $window_label wait; halting"; break; }
      iteration=$((iteration - 1))
      continue
    fi
  fi

  echo "[autonomate] iteration $iteration (elapsed $(( (now-start_ts)/60 ))m, breaker $breaker/$GLUERUN_MAX_CONSEC_FAILS)"
  cycle_out="$("$reconcile_script" --actuate 2>&1)" || true
  printf '%s\n' "$cycle_out" | sed 's/^/  /'

  field() { printf '%s\n' "$cycle_out" | sed -n "s/^$1=//p" | tail -1; }
  dispatched="$(field dispatched_this_run)"; integrated="$(field integrated_this_run)"
  faild="$(field failed_dispatches)"; faili="$(field failed_integrations)"
  planner_failures="$(field planner_failures_this_run)"
  planner_backoff_deferred="$(field planner_backoff_active_this_run)"
  l1_import_rejections="$(field l1_import_rejections_this_run)"
  reaped_ok="$(field reaped_ok)"; reaped_failures="$(field reaped_failures)"
  workers_running="$(field workers_running)"
  promoted="$(field gates_promoted_this_run)"
  for v in dispatched integrated faild faili planner_failures planner_backoff_deferred l1_import_rejections reaped_ok reaped_failures workers_running promoted; do [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
  if [[ "$planner_backoff_at_cycle_start" -eq 1 && "$planner_failures" -gt 0 ]]; then
    echo "  [autonomate] active planner backoff made planner refusal neutral; ignoring $planner_failures planner failure(s) for breaker accounting"
    gluerun_append_event "autonomate.planner_backoff_neutral" \
      "active planner backoff suppressed repeated planner failure accounting" \
      "{\"iteration\":$iteration,\"suppressedPlannerFailures\":$planner_failures}"
    planner_failures=0
    planner_backoff_deferred=1
  fi
  gen_complete="no"; printf '%s\n' "$cycle_out" | grep -q 'all-areas-complete' && gen_complete="yes"
  gen_made="no"; printf '%s\n' "$cycle_out" | grep -q 'gen:.*generated:' && gen_made="yes"
  # Reconcile's frontier selector already performs the authoritative duplicate,
  # dependency, lease, and scope checks. This post-cycle value is telemetry only;
  # avoid the legacy per-task duplicate scan on large campaigns.
  ready_now="$(gluerun_list_status_ready_tasks | wc -l | tr -d ' ')"
  active_now="$(gluerun_active_lease_count)"

  progress="no"
  if [[ "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" ]]; then
    # Detached: a dispatch returns immediately and proves nothing, so it is NOT
    # progress (otherwise every failure cycle would re-dispatch the freed slot
    # and reset the breaker, which could then never trip). Progress is an
    # observed completion, an integration, or new planned work; reap failures
    # join the failure side below.
    { [[ "$reaped_ok" -gt 0 ]] || [[ "$integrated" -gt 0 ]] || [[ "$gen_made" == "yes" ]] || [[ "$promoted" -gt 0 ]]; } && progress="yes"
  else
    { [[ "$dispatched" -gt 0 && "$faild" -eq 0 ]] || [[ "$integrated" -gt 0 ]] || [[ "$gen_made" == "yes" ]] || [[ "$promoted" -gt 0 ]]; } && progress="yes"
  fi

  if [[ "$progress" == "yes" ]]; then
    gluerun_breaker_reset
  elif [[ "$faild" -gt 0 || "$faili" -gt 0 || "$planner_failures" -gt 0 || "$l1_import_rejections" -gt 0 || ( "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" && "$reaped_failures" -gt 0 ) ]]; then
    # C2 (0.5.0): a usage-limit / 403 / overload window can poison the decider,
    # auditor, L1 fanout, or dispatch paths, producing cycle failures with NO
    # active quota backoff. When a validated runner-result/provider-error pair
    # exists in this cycle (gluerun_cycle_limit_window_evidence_json), ARM a
    # quota backoff so the next iteration sleeps
    # through, and do NOT increment the breaker. Import rejections are
    # deterministic validation outcomes (duplicate candidates, bad batches) and
    # can never be quota evidence — they are excluded from limit ELIGIBILITY
    # (0.4.0 counted them, arming false 30-minute backoffs from healthy cycles)
    # though they still count toward the breaker branch. FAIL-CLOSED: no
    # evidence -> the breaker trips, so genuine code failures are unaffected.
    # GLUERUN_LIMIT_SLEEPTHROUGH=0 (or legacy GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH=1,
    # deprecated) forces the always-trip behavior.
    limit_eligible=$((faild + faili + planner_failures))
    [[ "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" ]] && limit_eligible=$((limit_eligible + reaped_failures))
    sleepthrough="${GLUERUN_LIMIT_SLEEPTHROUGH:-1}"
    [[ "${GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH:-0}" == "1" ]] && sleepthrough=0
    limit_evidence=""
    if [[ "$sleepthrough" == "1" && "$limit_eligible" -gt 0 ]]; then
      limit_evidence="$(gluerun_cycle_limit_window_evidence_json 2>/dev/null || true)"
    fi
    ev_resultref=""
    ev_class=""
    if [[ -n "$limit_evidence" ]]; then
      # The class must come from the evidence, not be assumed. This site used to
      # hardcode "quota", so an overload window re-armed a 30-minute backoff here
      # even once the classifier had told the truth about it.
      # Class first: `read` folds every remaining field into the last variable,
      # so a resultRef containing spaces survives intact.
      read -r ev_class ev_resultref < <(printf '%s' "$limit_evidence" | python3 -c '
import json, sys
d = json.load(sys.stdin)
kinds = {"usage-limit": "quota", "entitlement": "quota", "overloaded": "provider-overloaded"}
print(kinds.get(d.get("kind"), ""), d.get("resultRef", ""))
' 2>/dev/null || true)
    fi
    if [[ -n "$ev_resultref" && -n "$ev_class" ]] \
      && gluerun_planner_backoff_set "$ev_class" "RUN-limit-chokepoint" "breaker-chokepoint" "$ev_resultref"; then
      echo "  [autonomate] no progress + structured provider limit evidence ($ev_resultref); armed $ev_class backoff, NO breaker increment (breaker stays $breaker/$GLUERUN_MAX_CONSEC_FAILS)"
      gluerun_append_event "autonomate.limit_window_detected" "provider window at breaker chokepoint; armed $ev_class backoff instead of tripping" "{\"iteration\":$iteration,\"failureClass\":\"$ev_class\",\"breaker\":$breaker,\"failD\":$faild,\"failI\":$faili,\"plannerFail\":$planner_failures,\"importReject\":$l1_import_rejections,\"evidence\":$limit_evidence}"
    else
      nb="$(gluerun_breaker_trip)"; echo "  [autonomate] no progress + failure; breaker -> $nb"
    fi
  fi

  gluerun_write_status "$iteration" "running (disp=$dispatched int=$integrated failD=$faild failI=$faili planFail=$planner_failures planBackoff=$planner_backoff_deferred importReject=$l1_import_rejections reapOK=$reaped_ok reapFail=$reaped_failures workers=$workers_running)"

  # Periodic supervisor briefing (0.10.0). BYTE-INERT when the interval knob is
  # unset/0: a single string test skips the whole block, so no supervisor/ dir,
  # stamp, or SUP run is ever created. When enabled, brief at most once per
  # interval, never during a quota/planner backoff, and stamp BEFORE spawning so
  # an immediate next cycle cannot double-spawn. The briefing is a detached,
  # log-redirected background readonly session — it never blocks the loop.
  sup_int="${GLUERUN_SUPERVISOR_INTERVAL_MIN:-0}"
  if [[ "$sup_int" =~ ^[0-9]+$ && "$sup_int" -gt 0 && -z "$bo_json" ]]; then
    sup_dir="$GLUERUN_STATE_DIR/supervisor"
    sup_last=0
    [[ -f "$sup_dir/last-run" ]] && sup_last="$(cat "$sup_dir/last-run" 2>/dev/null || echo 0)"
    [[ "$sup_last" =~ ^[0-9]+$ ]] || sup_last=0
    if (( now - sup_last >= sup_int * 60 )); then
      mkdir -p "$sup_dir"
      printf '%s\n' "$now" >"$sup_dir/last-run"
      ( "$(gluerun_bash_bin)" "$SCRIPT_DIR/supervise.sh" --once >>"$sup_dir/spawn.log" 2>&1 & ) || true
    fi
  fi

  # DAG exhausted: planner says all areas complete and nothing is left to do.
  if [[ "$gen_complete" == "yes" && "$ready_now" -eq 0 && "$active_now" -eq 0 ]]; then
    echo "[autonomate] DAG exhausted (all areas complete); halting"
    gluerun_write_status "$iteration" "stopped (DAG complete)"
    gluerun_append_event "autonomate.stopped" "stopped: DAG complete" "{\"iteration\":$iteration}"
    break
  fi

  [[ "$once" == "yes" ]] && { echo "[autonomate] --once: single iteration done"; break; }
  # Interruptible (0.5.0): STOP is honored mid-nap (0.4.0 checked only at loop
  # top, so a STOP written during the sleep waited out the full nap); WAKE
  # ends it early without killing sleep children (which killed the whole loop
  # in the field).
  gluerun_interruptible_sleep "$sleep_secs" || true
done

gluerun_append_event "autonomate.exited" "autonomous loop exited" "{\"iterations\":$iteration}"
echo "[autonomate] done after $iteration iteration(s). STATUS: $GLUERUN_STATUS_FILE"

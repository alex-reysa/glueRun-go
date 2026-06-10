#!/usr/bin/env bash
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
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
once="no"
[[ "${1:-}" == "--once" ]] && once="yes"

gluerun_ensure_state_dirs
gluerun_require_target_branch

pidfile="$GLUERUN_STATE_DIR/autonomate.pid"
if [[ -f "$pidfile" ]]; then
  oldpid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    echo "autonomate already running (pid $oldpid); exiting"
    exit 0
  fi
fi
echo "$$" >"$pidfile"
cleanup() { [[ "$(cat "$pidfile" 2>/dev/null)" == "$$" ]] && rm -f "$pidfile"; }
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

  # Quota usage-limit window: a planner backoff with failureClass=quota means the
  # Claude/codex *session usage limit* is open. Refusing to plan is correct, but
  # those refusals are NOT code failures and must not trip the circuit breaker;
  # instead the loop sleeps through the window so it auto-recovers when the limit
  # resets. ONLY the "quota" class is special-cased — every other failure class
  # falls through to the normal cycle below and still counts toward the breaker.
  # STOP is honored before and after the nap, and a total wait budget escalates an
  # unbounded limit to STOP rather than idling forever. With no active quota
  # backoff this block is a no-op and behavior is identical to before.
  bo_json="$(gluerun_planner_backoff_active_json 2>/dev/null || true)"
  if [[ -n "$bo_json" ]]; then
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
    if [[ "$bo_class" == "quota" && "$bo_remaining" -gt 0 ]]; then
      if [[ "$quota_waited_total" -ge "$quota_wait_budget" ]]; then
        echo "[autonomate] quota wait budget exhausted (${quota_waited_total}s >= ${quota_wait_budget}s); setting STOP"
        : >"$GLUERUN_STOP_FILE"
        gluerun_write_status "$iteration" "stopped (quota wait budget ${quota_wait_budget}s exhausted)"
        gluerun_append_event "autonomate.stopped" "stopped: quota wait budget exhausted" "{\"iteration\":$iteration,\"quotaWaitedTotal\":$quota_waited_total}"
        break
      fi
      nap="$bo_remaining"; [[ "$nap" -gt "$quota_sleep_cap" ]] && nap="$quota_sleep_cap"
      quota_waited_total=$((quota_waited_total + nap))
      echo "[autonomate] planner quota window open (${bo_remaining}s left); sleeping ${nap}s WITHOUT breaker increment (waited ${quota_waited_total}s)"
      gluerun_append_event "autonomate.quota_wait" "sleeping through planner quota window" "{\"iteration\":$iteration,\"remainingSec\":$bo_remaining,\"napSec\":$nap,\"quotaWaitedTotal\":$quota_waited_total}"
      gluerun_write_status "$iteration" "sleeping through quota window (${bo_remaining}s left, waited ${quota_waited_total}s)"
      [[ "$once" == "yes" ]] && { echo "[autonomate] --once: quota wait detected, single iteration done"; break; }
      sleep "$nap"
      gluerun_stop_requested && { echo "[autonomate] STOP during quota wait; halting"; break; }
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
  l1_import_rejections="$(field l1_import_rejections_this_run)"
  reaped_ok="$(field reaped_ok)"; reaped_failures="$(field reaped_failures)"
  workers_running="$(field workers_running)"
  for v in dispatched integrated faild faili planner_failures l1_import_rejections reaped_ok reaped_failures workers_running; do [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
  gen_complete="no"; printf '%s\n' "$cycle_out" | grep -q 'all-areas-complete' && gen_complete="yes"
  gen_made="no"; printf '%s\n' "$cycle_out" | grep -q 'gen:.*generated:' && gen_made="yes"
  ready_now="$(gluerun_list_ready_tasks | wc -l | tr -d ' ')"
  active_now="$(gluerun_active_lease_count)"

  progress="no"
  if [[ "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" ]]; then
    # Detached: a dispatch returns immediately and proves nothing, so it is NOT
    # progress (otherwise every failure cycle would re-dispatch the freed slot
    # and reset the breaker, which could then never trip). Progress is an
    # observed completion, an integration, or new planned work; reap failures
    # join the failure side below.
    { [[ "$reaped_ok" -gt 0 ]] || [[ "$integrated" -gt 0 ]] || [[ "$gen_made" == "yes" ]]; } && progress="yes"
  else
    { [[ "$dispatched" -gt 0 && "$faild" -eq 0 ]] || [[ "$integrated" -gt 0 ]] || [[ "$gen_made" == "yes" ]]; } && progress="yes"
  fi

  if [[ "$progress" == "yes" ]]; then
    gluerun_breaker_reset
  elif [[ "$faild" -gt 0 || "$faili" -gt 0 || "$planner_failures" -gt 0 || "$l1_import_rejections" -gt 0 || ( "${GLUERUN_DETACHED_DISPATCH:-0}" == "1" && "$reaped_failures" -gt 0 ) ]]; then
    # C2: a usage-limit / 403-org-disabled / overload window can poison the
    # decider, auditor, L1 fanout, or dispatch paths -- or surface as a planner
    # codex-exit (the 403 markers are outside the planner quota classifier) --
    # producing cycle failures with NO active quota backoff. C1 only sleeps
    # through the planner-backoff path, so those windows tripped the breaker and
    # caused ~2h halts for a condition that self-heals. If this cycle's role logs
    # carry limit/403 markers, ARM a quota backoff so the NEXT iteration sleeps
    # through (C1's bounded, budget-capped, STOP-honored nap) and do NOT increment
    # the breaker. Detection is FAIL-CLOSED: no markers -> not a limit window ->
    # the breaker still trips, so genuine code failures are unaffected.
    # GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH=1 forces the legacy always-trip behavior.
    if [[ "${GLUERUN_DISABLE_LIMIT_SLEEPTHROUGH:-0}" != "1" ]] && gluerun_cycle_limit_window_detected; then
      gluerun_planner_backoff_set quota "RUN-limit-chokepoint" "breaker-chokepoint" ""
      echo "  [autonomate] no progress + LIMIT/403-induced failure; armed quota backoff, NO breaker increment (breaker stays $breaker/$GLUERUN_MAX_CONSEC_FAILS)"
      gluerun_append_event "autonomate.limit_window_detected" "limit/403 window at breaker chokepoint; armed quota backoff instead of tripping" "{\"iteration\":$iteration,\"breaker\":$breaker,\"failD\":$faild,\"failI\":$faili,\"plannerFail\":$planner_failures,\"importReject\":$l1_import_rejections}"
    else
      nb="$(gluerun_breaker_trip)"; echo "  [autonomate] no progress + failure; breaker -> $nb"
    fi
  fi

  gluerun_write_status "$iteration" "running (disp=$dispatched int=$integrated failD=$faild failI=$faili planFail=$planner_failures importReject=$l1_import_rejections reapOK=$reaped_ok reapFail=$reaped_failures workers=$workers_running)"

  # DAG exhausted: planner says all areas complete and nothing is left to do.
  if [[ "$gen_complete" == "yes" && "$ready_now" -eq 0 && "$active_now" -eq 0 ]]; then
    echo "[autonomate] DAG exhausted (all areas complete); halting"
    gluerun_write_status "$iteration" "stopped (DAG complete)"
    gluerun_append_event "autonomate.stopped" "stopped: DAG complete" "{\"iteration\":$iteration}"
    break
  fi

  [[ "$once" == "yes" ]] && { echo "[autonomate] --once: single iteration done"; break; }
  sleep "$sleep_secs"
done

gluerun_append_event "autonomate.exited" "autonomous loop exited" "{\"iterations\":$iteration}"
echo "[autonomate] done after $iteration iteration(s). STATUS: $GLUERUN_STATUS_FILE"

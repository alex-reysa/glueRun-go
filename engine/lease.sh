#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

lease_dir="$SINGULAR_STATE_DIR/leases"
mkdir -p "$lease_dir"

cmd="${1:-}"
shift || true

case "$cmd" in
  list)
    find "$lease_dir" -maxdepth 1 -name '*.json' -type f -print | sort
    ;;
  create)
    task_id=""
    branch=""
    area=""
    owner=""
    scope=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --task) task_id="$2"; shift 2 ;;
        --branch) branch="$2"; shift 2 ;;
        --area) area="$2"; shift 2 ;;
        --owner) owner="$2"; shift 2 ;;
        --scope) scope="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$task_id" || -z "$branch" || -z "$area" || -z "$owner" ]]; then
      echo "usage: $0 create --task TASK --branch BRANCH --area AREA --owner OWNER [--scope SCOPE]" >&2
      exit 2
    fi
    singular_lease_write "$task_id" "$branch" "$area" "$owner" "$scope" "planned"
    echo "$(singular_lease_path "$task_id")"
    ;;
  set-status)
    task_id="${1:-}"
    status="${2:-}"
    if [[ -z "$task_id" || -z "$status" ]]; then
      echo "usage: $0 set-status TASK STATUS" >&2
      exit 2
    fi
    if ! singular_lease_set_status "$task_id" "$status"; then
      echo "no lease for task: $task_id" >&2
      exit 2
    fi
    echo "$(singular_lease_path "$task_id")"
    ;;
  show)
    task_id="${1:-}"
    if [[ -z "$task_id" ]]; then
      echo "usage: $0 show TASK" >&2
      exit 2
    fi
    cat "$lease_dir/$task_id.json"
    ;;
  *)
    echo "usage: $0 {list|create|set-status|show}" >&2
    exit 2
    ;;
esac

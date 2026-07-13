#!/usr/bin/env bash
# ctx-artifact-scan.sh — read-only secret detection for durable context artifacts.
#
# This file only enumerates and scans artifacts. It does not rename, delete,
# quarantine, emit events, or alter prompt assembly.

gluerun_ctx_artifact_scan_paths() {
  local run_dir="$1"
  local p

  for p in \
    "$run_dir/implementer-capsule.json" \
    "$run_dir/reviewer-capsule.json" \
    "$run_dir/session-implementer.json" \
    "$run_dir/session-reviewer.json" \
    "$run_dir/session-planner.json" \
    "$run_dir/planner-session.json" \
    "$run_dir/packet.json" \
    "$run_dir/paired-audit.json" \
    "$run_dir/paired-audit-raw.json"; do
    [[ -f "$p" ]] && printf '%s\n' "$p"
  done

  if [[ -d "$run_dir/sessions/planner" ]]; then
    find "$run_dir/sessions/planner" -type f -name '*.json' -print 2>/dev/null
  fi

  find "$run_dir" -type f \( -name 'plan-critique.json' -o -name 'plan-critique-raw.json' -o -name 'critique.json' \) -print 2>/dev/null
}

gluerun_ctx_artifact_scan() {
  local run_dir="$1"
  [[ -n "$run_dir" && -d "$run_dir" ]] || {
    echo "secret-scan: artifacts path is not a directory: $run_dir" >&2
    return 2
  }

  if [[ "$(type -t gluerun_secret_scan_patterns)" != "function" ]]; then
    echo "secret-scan: internal error: secret patterns unavailable" >&2
    return 2
  fi

  local hits=0
  local file label regex m line_no line_text

  while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] || continue
    while IFS="$(printf '\t')" read -r label regex; do
      [[ -n "$label" && -n "$regex" ]] || continue
      m="$(LC_ALL=C grep -anE -e "$regex" "$file" 2>/dev/null || true)"
      if [[ -n "$m" ]]; then
        echo "secret-scan: $label match in artifact: $file" >&2
        while IFS= read -r line; do
          line_no="${line%%:*}"
          line_text="${line#*:}"
          printf '    %s:%s\n' "$line_no" "$line_text" >&2
        done <<<"$m"
        hits=$((hits + 1))
      fi
    done < <(gluerun_secret_scan_patterns)
  done < <(gluerun_ctx_artifact_scan_paths "$run_dir" | sort -u)

  if [[ "$hits" -gt 0 ]]; then
    echo "secret-scan: $hits potential secret(s) found; refusing." >&2
    return 2
  fi
  echo "secret-scan: clean"
}

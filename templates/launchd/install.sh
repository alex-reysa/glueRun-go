#!/usr/bin/env bash
set -euo pipefail

# Install (but do NOT load) the singular orchestrator LaunchAgent.
#
# Per the bootstrap plan, the recurring schedule must not be loaded until one
# manual dry run and one manual full loop have passed.
#
# Usage: install.sh <consumer-repo-path>
#
# This script only:
#   1. resolves the explicit consumer repository and substitutes every
#      __SINGULAR_*__ placeholder in the plist template;
#   2. writes the result to ~/Library/LaunchAgents/;
#   3. prints the exact commands to enable it when you are ready.
# It never calls launchctl load.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine_home="$(cd "$script_dir/../.." && pwd -P)"
template="$script_dir/com.singular.orchestrator.plist"
runner="$script_dir/run-orchestrator.sh"
label="com.singular.orchestrator"
dest_dir="$HOME/Library/LaunchAgents"
dest="$dest_dir/$label.plist"
target_branch="${SINGULAR_TARGET_BRANCH:-codex/singular-bootstrap-target}"

usage() {
  echo "usage: $0 <consumer-repo-path>" >&2
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 2
fi

consumer_path="$1"
if [[ ! -d "$consumer_path" ]]; then
  echo "consumer repo path is not a directory: $consumer_path" >&2
  exit 1
fi

if ! repo_root="$(git -C "$consumer_path" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "consumer repo path is not inside a Git worktree: $consumer_path" >&2
  exit 1
fi
repo_root="$(cd "$repo_root" && pwd -P)"

if [[ ! -f "$template" ]]; then
  echo "plist template not found: $template" >&2
  exit 1
fi
if [[ ! -x "$runner" ]]; then
  echo "launchd runner is not executable: $runner" >&2
  exit 1
fi

xml_escape() {
  sed -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

sed_replacement() {
  sed -e 's/[\\&|]/\\&/g'
}

repo_replacement="$(printf '%s' "$repo_root" | xml_escape | sed_replacement)"
engine_replacement="$(printf '%s' "$engine_home" | xml_escape | sed_replacement)"
runner_replacement="$(printf '%s' "$runner" | xml_escape | sed_replacement)"
branch_replacement="$(printf '%s' "$target_branch" | xml_escape | sed_replacement)"

mkdir -p "$dest_dir"
tmp_dest="$(mktemp "$dest_dir/.$label.plist.XXXXXX")"
trap 'rm -f "$tmp_dest"' EXIT
sed \
  -e "s|__SINGULAR_REPO_ROOT__|$repo_replacement|g" \
  -e "s|__SINGULAR_ENGINE_HOME__|$engine_replacement|g" \
  -e "s|__SINGULAR_RUNNER__|$runner_replacement|g" \
  -e "s|__SINGULAR_TARGET_BRANCH__|$branch_replacement|g" \
  "$template" >"$tmp_dest"

if grep -Eq '__SINGULAR_[A-Z0-9_]+__' "$tmp_dest"; then
  echo "generated plist still contains an unsubstituted Singular placeholder" >&2
  exit 1
fi

mv "$tmp_dest" "$dest"
trap - EXIT

echo "installed (not loaded): $dest"
echo "consumer repo:          $repo_root"
echo "engine home:            $engine_home"
echo "launchd runner:          $runner"
echo "target branch:           $target_branch"
echo ""
echo "The agent is installed with Disabled=true and will NOT run yet."
echo "After a manual full loop passes, enable it with:"
echo ""
echo "  # flip ONLY the Disabled key's value to false, then load:"
echo "  /usr/bin/sed -i '' '/<key>Disabled<\\/key>/{N;s#<true/>#<false/>#;}' \"$dest\""
echo "  launchctl bootstrap gui/\$(id -u) \"$dest\""
echo "  launchctl enable gui/\$(id -u)/$label"
echo ""
echo "To verify environment without launchd:"
echo "  SINGULAR_ROOT=\"$repo_root\" SINGULAR_ENGINE_HOME=\"$engine_home\" SINGULAR_LAUNCHD_MODE=--status \"\${SINGULAR_BASH_BIN:-bash}\" \"$runner\""
echo ""
echo "To remove later:"
echo "  launchctl bootout gui/\$(id -u)/$label 2>/dev/null || true"
echo "  rm -f \"$dest\""

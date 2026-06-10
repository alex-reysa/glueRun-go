#!/usr/bin/env bash
set -euo pipefail

# Install (but do NOT load) the glueRun-go orchestrator LaunchAgent.
#
# Per the bootstrap plan, the recurring schedule must not be loaded until one
# manual dry run and one manual full loop have passed. This script only:
#   1. substitutes __GLUERUN_REPO_ROOT__ in the plist template;
#   2. writes the result to ~/Library/LaunchAgents/;
#   3. prints the exact commands to enable it when you are ready.
# It never calls launchctl load.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
template="$script_dir/com.gluerun.orchestrator.plist"
label="com.gluerun.orchestrator"
dest_dir="$HOME/Library/LaunchAgents"
dest="$dest_dir/$label.plist"

if [[ ! -f "$template" ]]; then
  echo "plist template not found: $template" >&2
  exit 1
fi

mkdir -p "$dest_dir"
sed "s#__GLUERUN_REPO_ROOT__#$repo_root#g" "$template" >"$dest"

echo "installed (not loaded): $dest"
echo "repo_root substituted:  $repo_root"
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
echo "  GLUERUN_LAUNCHD_MODE=--status bash \"$repo_root/scripts/orchestration/launchd/run-orchestrator.sh\""
echo ""
echo "To remove later:"
echo "  launchctl bootout gui/\$(id -u)/$label 2>/dev/null || true"
echo "  rm -f \"$dest\""

#!/usr/bin/env bash
# Install the gluerun orchestration engine for the current machine.
#
#   bash install.sh            # install this checkout's version
#
# Layout created:
#   ~/.gluerun/versions/<ver>/    versioned engine (engine, schemas, cli, plugin, ...)
#   ~/.gluerun/current  -> versions/<ver>
#   ~/.gluerun/bin/gluerun -> versions/<ver>/cli/gluerun   (add ~/.gluerun/bin to PATH)
#
# Multiple versions coexist; each repo pins which it uses (.gluerun-version /
# gluerun.config.json engineVersion). `gluerun update <ver>` repins a repo.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SRC/VERSION" && -f "$SRC/engine/lib.sh" ]] || {
  echo "install.sh must run from an engine checkout (with VERSION + engine/)" >&2; exit 1; }

VER="$(tr -d '[:space:]' < "$SRC/VERSION")"
[[ -n "$VER" ]] || { echo "install.sh: VERSION is empty — refusing to install (would wipe versions/*)" >&2; exit 1; }
GLUERUN_HOME="${GLUERUN_HOME:-$HOME/.gluerun}"
DEST="$GLUERUN_HOME/versions/$VER"

echo "Installing gluerun engine $VER -> $DEST"
mkdir -p "$DEST" "$GLUERUN_HOME/bin"

# Copy the engine payload, preserving exec bits. Exclude runtime/VCS cruft.
#
# Optional items must not abort the install. The `[[ -e ]] &&` form says these
# are optional, but under `set -e` a missing one makes copy() return 1 and kills
# the script — mid-loop, after some payload is already in place, leaving a
# half-populated version dir while `current` still points at the old release.
# An explicit `return 0` makes the stated intent actually true. (Hit for real:
# an empty, untracked `promoters/` vanished from the checkout and took the whole
# install down with it, silently, after copying engine/ and schemas/.)
copy() {
  [[ -e "$SRC/$1" ]] || return 0
  cp -Rp "$SRC/$1" "$DEST/"
}
rm -rf "$DEST"/* 2>/dev/null || true
for item in engine schemas promoters templates plugin gluerun-ext cli migrations VERSION SCHEMA_VERSION CHANGELOG.md; do
  copy "$item"
done

# Normalize exec bits (defensive against transfer mode loss).
chmod +x "$DEST/cli/gluerun" 2>/dev/null || true
find "$DEST/engine" "$DEST/tests" "$DEST/gluerun-ext" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

# current -> this version; bin launcher -> this version's CLI.
ln -sfn "$DEST" "$GLUERUN_HOME/current"
ln -sfn "$DEST/cli/gluerun" "$GLUERUN_HOME/bin/gluerun"

echo "Installed. 'current' -> $VER"

# PATH guidance.
case ":$PATH:" in
  *":$GLUERUN_HOME/bin:"*) echo "~/.gluerun/bin is already on PATH." ;;
  *)
    echo ""
    echo "Add gluerun to PATH (append to your ~/.zshrc or ~/.bashrc):"
    echo "    export PATH=\"\$HOME/.gluerun/bin:\$PATH\""
    if [[ -w /usr/local/bin ]]; then
      ln -sfn "$GLUERUN_HOME/bin/gluerun" /usr/local/bin/gluerun
      echo "(also linked /usr/local/bin/gluerun for this session)"
    fi
    ;;
esac

echo ""
echo "Verify:  gluerun version  &&  gluerun doctor"

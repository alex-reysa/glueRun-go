#!/usr/bin/env bash
# ctx-rehydrate-authored-packet.sh — pure, read-only authored-knowledge packet
# composer (stage S5-routing, node `rehydrate-path`, layer engine_runtime;
# singular-brain integration point 3). Sourced exactly once by the
# context-evolution loader block in lib.sh (it matches the ctx-*.sh glob). This
# file DEFINES new functions only and is present-but-uncalled by every existing
# engine/CLI/driver path, so with it sourced the engine stays byte-identical to
# prior behavior.
#
# This is the THIRD slice of the explicitly-OPTIONAL authored-knowledge
# deliverable. TASK-0058 (gluerun_ctx_rehydrate_authored_select) and TASK-0059
# (gluerun_ctx_rehydrate_authored_eligible) reduce a FIXTURE authored-knowledge
# manifest to the eligible entries as JSON Lines. This slice composes those two
# integrated leaves into the two artifacts the eventual wire-in will merge: an
# injectable capped packet SECTION and the authored MANIFEST entries recording
# which authored ids were injected. It is NOT part of the `rehydrate-path` node's
# requiredCompletion and does NOT gate the node. GLUERUN_CTX_MANIFEST (default 0)
# gates the later config/driver wire-in, NOT this pure leaf. It takes NO
# dependency on any singular-brain runtime.
#
#   gluerun_ctx_rehydrate_authored_render   <manifest-path> [trigger ...]
#   gluerun_ctx_rehydrate_authored_manifest <manifest-path> [trigger ...]
#
# Both compose `gluerun_ctx_rehydrate_authored_select <manifest-path>` piped
# through `gluerun_ctx_rehydrate_authored_eligible [trigger ...]` — inheriting the
# quarantine, description_unverified, stale-freshness, and trigger-mismatch
# exclusions of those integrated leaves; the composer introduces no content that
# bypasses them — and resolve each eligible entry's body (an inline `body`, or the
# contents of a `path`-backed entry read READ-ONLY):
#
#   - `..._render` prints the injectable packet section on stdout: one labeled
#     `=== authored:<id> ===` section per eligible entry, headed by an explicit
#     AUTHORED-KNOWLEDGE / NOT AUTHORITATIVE marker, then the resolved body,
#     truncated to at most GLUERUN_CONTEXT_SECTION_MAX_CHARS (default 4000,
#     honoring the engine/lib.sh knob) with a stable truncation marker. No
#     rendered section is ever marked authoritative.
#   - `..._manifest` prints a deterministic JSON sources list on stdout: one
#     {id, sha256, class:"authored-knowledge", authoritative:false} per injected
#     id, the sha256 taken over that entry's resolved body bytes ("which authored
#     entries, which hashes") — recording which authored entries were injected,
#     like any other rehydration source, and NEVER as authoritative.
#
# Deterministic: entries are emitted in a fixed id-sorted order, so identical
# manifest bytes and triggers yield byte-identical section and manifest.
#
# Pure and READ-ONLY: it reads the manifest and path-backed bodies but never
# writes, renames, or deletes anything; appends no events; and never exits
# non-zero on well-formed input. An absent, empty, or malformed manifest yields an
# empty section and empty manifest sources (fail-soft).

# gluerun_ctx_rehydrate_authored_render <manifest-path> [trigger ...]
gluerun_ctx_rehydrate_authored_render() {
  local manifest="${1-}"
  [[ $# -gt 0 ]] && shift
  gluerun_ctx_rehydrate_authored_select "$manifest" \
    | gluerun_ctx_rehydrate_authored_eligible "$@" \
    | _gluerun_ctx_authored_packet_py packet "${GLUERUN_CONTEXT_SECTION_MAX_CHARS:-4000}"
}

# gluerun_ctx_rehydrate_authored_manifest <manifest-path> [trigger ...]
gluerun_ctx_rehydrate_authored_manifest() {
  local manifest="${1-}"
  [[ $# -gt 0 ]] && shift
  gluerun_ctx_rehydrate_authored_select "$manifest" \
    | gluerun_ctx_rehydrate_authored_eligible "$@" \
    | _gluerun_ctx_authored_packet_py manifest "${GLUERUN_CONTEXT_SECTION_MAX_CHARS:-4000}"
}

# Internal: the pure Python renderer. argv: mode (packet|manifest) and the
# section cap. Reads the eligible JSON Lines on stdin (one authored-knowledge
# record per line, each carrying id / source(body|path) / body|path /
# class=authored-knowledge / authoritative=false), resolves each entry's body
# READ-ONLY, and emits either the labeled packet section or the JSON sources
# manifest in a fixed id-sorted order. No I/O beyond reading path-backed bodies
# and writing stdout; no side effects.
_gluerun_ctx_authored_packet_py() {
  # The program is passed via -c (NOT a heredoc) so python's stdin stays bound to
  # the real eligible JSONL rather than the script text.
  python3 -c '
import hashlib
import json
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "packet"
try:
    cap = int(sys.argv[2])
except (ValueError, IndexError):
    cap = 4000

# Explicit class marker heading every rendered section: authored-knowledge, human
# curated, and NEVER authoritative. Distinct from durable host-verified artifacts
# and from model-authored (tainted) records.
MARKER = "[authored-knowledge -- not authoritative]"
TRUNC = "\n[... authored section truncated to fit the context budget ...]"


def section_cap(text):
    if len(text) <= cap:
        return text
    keep = max(0, cap - len(TRUNC))
    return text[:keep] + TRUNC


records = []
for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    # Fail-soft: a malformed line contributes nothing.
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if not isinstance(rec, dict):
        continue
    sid = rec.get("id")
    if not isinstance(sid, str) or not sid:
        continue

    # Resolve the entry body READ-ONLY: an inline body, or the contents of a
    # path-backed entry. Quarantine/exclusion has already been applied upstream by
    # the integrated select/eligible leaves.
    source = rec.get("source")
    body = None
    if source == "body":
        b = rec.get("body")
        if isinstance(b, str):
            body = b.encode("utf-8")
    elif source == "path":
        path = rec.get("path")
        if isinstance(path, str) and path:
            try:
                with open(path, "rb") as fh:
                    body = fh.read()
            except OSError:
                # A declared-but-unreadable path-backed body contributes nothing;
                # stay pure and non-fatal.
                body = None
    if body is None:
        continue

    records.append((sid, body))

# Deterministic, fixed order: sort by id (the same id sort select/eligible use).
records.sort(key=lambda r: r[0])

if mode == "manifest":
    obj = {
        "schema": "gluerun.orchestration.ctx-rehydrate-authored-manifest.v0",
        "sources": [
            {
                "id": sid,
                "sha256": hashlib.sha256(body).hexdigest(),
                "class": "authored-knowledge",
                "authoritative": False,
            }
            for sid, body in records
        ],
    }
    sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
    sys.stdout.write("\n")
else:
    # An empty selection yields an empty section (no stray output), fail-soft.
    if not records:
        sys.exit(0)
    parts = []
    for sid, body in records:
        parts.append("=== authored:%s ===" % sid)
        parts.append(MARKER)
        parts.append(section_cap(body.decode("utf-8", "replace")))
    sys.stdout.write("\n".join(parts))
    sys.stdout.write("\n")
' "$1" "$2"
}

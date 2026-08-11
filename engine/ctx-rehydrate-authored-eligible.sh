#!/usr/bin/env bash
# ctx-rehydrate-authored-eligible.sh — pure, read-only authored-knowledge
# eligibility filter (stage S5-routing, node `rehydrate-path`, layer
# engine_runtime; singular-brain integration point 3). Sourced exactly once by
# the context-evolution loader block in lib.sh (it matches the ctx-*.sh glob).
# This file DEFINES a new function only and is present-but-uncalled by every
# existing engine/CLI/driver path, so with it sourced the engine stays
# byte-identical to prior behavior.
#
# This is the SECOND slice of the explicitly-OPTIONAL authored-knowledge
# deliverable. The first slice (singular_ctx_rehydrate_authored_select) emits the
# surviving authored-knowledge entries as JSON Lines but does NOT filter on
# `load-when` or `freshness`. This slice adds that filter. It is NOT part of the
# `rehydrate-path` node's requiredCompletion and does NOT gate the node.
# SINGULAR_CTX_MANIFEST (default 0) gates the later packet wire-in, NOT this pure
# leaf. The JSONL contract is the whole interface: it takes NO dependency on any
# singular-brain runtime.
#
#   singular_ctx_rehydrate_authored_eligible <trigger> [<trigger> ...]
#
# Reads the selector's JSON Lines on stdin — one authored-knowledge record per
# line, each carrying "id", "source" (body|path), "class":"authored-knowledge",
# "authoritative":false, "load-when" (list), and "freshness" (string) — and a
# current trigger context in argv, and prints only the entries eligible to
# inject now, under the AUTHORED-KNOWLEDGE class rules:
#
#   - load-when matching: an entry is eligible iff its "load-when" list is empty
#     (the documented unconditional-baseline default) or contains at least one of
#     the supplied <trigger> values; ineligible entries are dropped.
#   - freshness gate: an entry whose "freshness" is a documented stale/expired
#     state (see STALE_FRESHNESS below) is NEVER emitted as current — it is
#     skipped, mirroring TASK-0058's `description_unverified` rule, so non-current
#     authored knowledge can never be presented as current or authoritative.
#   - class markers pass through unchanged: emitted entries retain
#     "class":"authored-knowledge" and "authoritative":false; the filter never
#     elevates an entry to authoritative.
#   - Output is deterministic: the eligible subset is emitted in the same fixed
#     id-sorted order as the selector, so identical input and triggers yield
#     byte-identical output.
#
# Pure and READ-ONLY: it reads stdin only and never writes, renames, or deletes
# anything; appends no events; and never exits non-zero on well-formed input.
# Malformed JSONL lines are skipped and empty input yields empty output
# (fail-soft).

# singular_ctx_rehydrate_authored_eligible <trigger> [<trigger> ...]
singular_ctx_rehydrate_authored_eligible() {
  # Triggers arrive as argv; the selector JSONL arrives on stdin. The pure
  # renderer reads stdin and receives the trigger context as its own argv. The
  # program is passed via -c (NOT a heredoc) so python's stdin stays bound to the
  # real selector JSONL rather than the script text.
  python3 -c '
import json
import sys

# Documented stale/expired freshness states. An authored-knowledge record whose
# freshness is one of these is non-current and is NEVER emitted as current, so it
# can never be presented as current or authoritative (mirrors the
# description_unverified rule from the selector slice). Matching is case-
# insensitive; every other freshness value (including "current", "fresh", and the
# empty string) passes the gate.
STALE_FRESHNESS = {"stale", "expired"}

# The current trigger context (may be empty). Order/duplication is irrelevant:
# load-when matching is set membership.
triggers = set(sys.argv[1:])

selected = []
for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    # Fail-soft: a malformed JSONL line is skipped, not fatal.
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if not isinstance(rec, dict):
        continue

    sid = rec.get("id")
    if not isinstance(sid, str) or not sid:
        continue

    # freshness gate: drop documented stale/expired records outright.
    fresh = rec.get("freshness")
    if isinstance(fresh, str) and fresh.strip().lower() in STALE_FRESHNESS:
        continue

    # load-when matching: eligible iff empty (unconditional baseline) or it
    # intersects the supplied trigger context.
    lw = rec.get("load-when")
    if not isinstance(lw, list):
        lw = []
    load_when = {v for v in lw if isinstance(v, str)}
    if load_when and load_when.isdisjoint(triggers):
        continue

    # Class markers pass through unchanged: the filter never elevates an entry to
    # authoritative. Re-serialize with sort_keys so the eligible subset is
    # byte-for-byte a subset of the selector emission.
    selected.append(rec)

# Deterministic, fixed order: the same id sort the selector uses.
selected.sort(key=lambda r: r["id"])
for rec in selected:
    sys.stdout.write(json.dumps(rec, sort_keys=True, ensure_ascii=False))
    sys.stdout.write("\n")
' _ "$@"
}

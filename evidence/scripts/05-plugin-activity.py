#!/usr/bin/env python3
"""Claim 5: what the two dsh plugins actually did during an agent run.

usage: 05-plugin-activity.py <session-home>

Pure log analysis -- no GPU, no model. Reads the dsh session log
(session.v3.jsonl.zstd) and reports:

  * trim activity      : compaction/prune events (span elisions) and tokens freed
  * guard activity     : CONVERGENCE_CHECK messages, with the fingerprint they named
  * blocks             : REPEAT_TOOL_BLOCKED
  * compaction health  : how many compactions ran and how many failed
  * verdict            : turn/end reason

Why this matters: on a 40K window these two plugins do the work that keeps a long
agent task alive. Their activity is the difference between "completed" and
"max-tokens" at the same context size.
"""
import json
import re
import subprocess
import sys
from collections import Counter


def load(home: str) -> list[dict]:
    """Find one session log under <home>/sessions and return its events.

    Accepts either a zstd-compressed `session.v3.jsonl.zstd` (what dsh writes) or
    a plain `.jsonl` file (what the packed evidence logs are), so this works
    against a live DSH_HOME and against the copies in ../logs/.
    """
    probe = subprocess.run(
        ["bash", "-c",
         f"find {home}/sessions -type f \\( -name 'session.v3.jsonl*' -o -name '*.jsonl*' \\) | head -1"],
        capture_output=True, text=True).stdout.strip()
    if not probe:
        sys.exit(f"no session log under {home}/sessions")
    if probe.endswith(".zstd"):
        raw = subprocess.run(["zstd", "-dc", "--", probe],
                             capture_output=True, text=True).stdout
    else:
        with open(probe, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    out = []
    for line in raw.split("\n"):
        if line.strip():
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def texts(obj, acc, prefix="CONVERGENCE_CHECK"):
    """Collect any text block starting with `prefix`, wherever it is nested."""
    if isinstance(obj, dict):
        if obj.get("type") == "text" and str(obj.get("text", "")).strip().startswith(prefix):
            acc.append(obj["text"].strip())
        for v in obj.values():
            texts(v, acc, prefix)
    elif isinstance(obj, list):
        for v in obj:
            texts(v, acc, prefix)


def main() -> None:
    home = sys.argv[1] if len(sys.argv) > 1 else "."
    evs = load(home)
    counts = Counter(e.get("type") for e in evs)

    print(f"session: {home}")
    print(f"events : {len(evs)}\n")

    # --- trim -------------------------------------------------------------
    prunes = [e for e in evs if e.get("type") == "compaction/prune"]
    print(f"=== trim (context-trim plugin) ===")
    print(f"  span elisions : {len(prunes)}")
    total = 0
    for i, e in enumerate(prunes, 1):
        d = e.get("data") or {}
        freed = d.get("shadowedTokenCount")
        total += freed or 0
        print(f"    {i:2d}. shadowed={d.get('shadowedSeqs')}  freed={freed} tokens")
    print(f"  total freed   : {total:,} tokens")
    print(f"  NOTE: 0 elisions is normal if the window had enough room --\n"
          f"        it means the context never hit the wall, not that trim is broken.\n")

    # --- guard ------------------------------------------------------------
    seen = []
    for e in evs:
        acc = []
        texts(e.get("data"), acc)
        for t in acc:
            if t not in seen:
                seen.append(t)
    blocked = sum(1 for e in evs if "REPEAT_TOOL_BLOCKED" in json.dumps(e, ensure_ascii=False))
    print(f"=== repeat detector (repeat-tool-breaker plugin) ===")
    print(f"  advisories    : {len(seen)}")
    for t in seen:
        first = t.split("\n")[0]
        m = re.search(r"([a-z]+:[^\s]+) has (?:now )?come up (\d+)", first)
        print(f"    {first[:100]}")
        if m:
            print(f"      -> fingerprint={m.group(1)}  count={m.group(2)}")
    print(f"  hard blocks   : {blocked}\n")

    # --- compaction -------------------------------------------------------
    cend = [e for e in evs if e.get("type") == "compaction/end"]
    errs = [e for e in cend if (e.get("data") or {}).get("error")]
    print(f"=== compaction health ===")
    print(f"  ran    : {len(cend)}")
    print(f"  failed : {len(errs)}")
    for e in errs[:5]:
        print(f"    ERR: {(e['data'].get('error') or '')[:95]}")
    print()

    # --- outcome ----------------------------------------------------------
    print(f"=== tool use ===")
    tc = Counter(e["data"].get("name") for e in evs if e.get("type") == "tool/call")
    print(f"  calls  : {counts.get('tool/call', 0)}  {dict(tc)}")
    print()
    print(f"=== outcome ===")
    for e in evs:
        if e.get("type") == "turn/end":
            print(f"  turn/end: {json.dumps(e['data'])}")


if __name__ == "__main__":
    main()

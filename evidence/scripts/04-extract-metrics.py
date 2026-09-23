#!/usr/bin/env python3
"""
Extract per-request prefill/TTFT/decode metrics from dsh session logs.

Per the b70-backend-test skill (v1.2.0): agent tasks (t3/t4/t5) run through the
dsh harness, so the three mandatory metrics are NOT "N/A" -- they are recoverable
from the JSONL session log the harness writes.

Log location:
  $DSH_HOME/sessions/<escaped-cwd>/session-<uuid>/session.v3.jsonl.zst*

Fields used (all times are epoch MILLISECONDS):
  step/start.time                              -> request send time
  assistant/message.usage.inputTokens          -> prompt tokens
  assistant/message.usage.outputTokens         -> completion tokens
  assistant/message.stream[].time / .time0     -> first chunk arrival
  assistant/message.stream[].dt[]              -> inter-chunk gaps (ms)

Derivation:
  TTFT        = (first_chunk_time - step/start.time) / 1000
  prefill_tps = inputTokens / TTFT
  decode_tps  = outputTokens / (sum(stream[].dt[]) / 1000)

Caveats implemented:
  - A turn whose only output is a tool call can have len(dt)==1; its decode
    rate is meaningless. Rows with len(dt) < 2 are flagged.
  - One task = many requests. Report per-request rows PLUS the aggregate.
  - The harness sends an ~18K-token system prompt, so request #1 carries a large
    prefill and a long TTFT. Flagged in the output.

Usage:
  ./extract_session_metrics.py <DSH_HOME> [--task LABEL] [--json OUT]
"""
import argparse
import glob
import json
import os
import subprocess
import sys


def read_zstd(path):
    """Stream-decompress a .zst JSONL log. Uses `zstd -dc --` (note the --)."""
    try:
        p = subprocess.run(["zstd", "-dc", "--", path],
                           capture_output=True, check=True)
        return p.stdout.decode("utf-8", "replace")
    except FileNotFoundError:
        # fall back to python zstandard if the CLI is absent
        try:
            import zstandard  # type: ignore
        except ImportError:
            sys.exit("need either the `zstd` CLI or the `zstandard` python package")
        with open(path, "rb") as f:
            dctx = zstandard.ZstdDecompressor()
            return dctx.stream_reader(f).read().decode("utf-8", "replace")
    except subprocess.CalledProcessError as e:
        sys.exit(f"zstd failed on {path}: {e.stderr.decode()[:200]}")


def find_logs(home, session=None, since=None, until=None):
    """Locate session logs.

    IMPORTANT: every dsh task run against the same DSH_HOME appends its own
    session directory. A naive glob therefore returns the UNION of every task
    ever run in that home, silently contaminating per-task metrics. Callers
    must either pass an explicit --session id, or a --since/--until window
    (HH:MM) that isolates one task.
    """
    pats = [
        os.path.join(home, "sessions", "**", "session*.jsonl.zst"),
        os.path.join(home, "sessions", "**", "session*.jsonl.zstd"),
        os.path.join(home, "sessions", "**", "session*.jsonl"),
    ]
    out = []
    for p in pats:
        out.extend(glob.glob(p, recursive=True))
    out = sorted(set(out))

    if session:
        out = [p for p in out if session in p]

    if since or until:
        import datetime as _dt

        def hhmm(s):
            h, m = (int(x) for x in s.split(":"))
            return h * 60 + m

        lo = hhmm(since) if since else 0
        hi = hhmm(until) if until else 24 * 60
        kept = []
        for p in out:
            t = _dt.datetime.fromtimestamp(os.path.getmtime(p))
            n = t.hour * 60 + t.minute
            if lo <= n <= hi:
                kept.append(p)
        out = kept

    return out


def parse(events):
    """Walk events, pairing step/start with the following assistant/message."""
    rows = []
    pending_start = None

    for ev in events:
        t = ev.get("type") or ev.get("kind") or ""
        time_ms = ev.get("time")

        if t in ("step/start", "step.start"):
            pending_start = time_ms
            continue

        if t in ("assistant/message", "assistant.message"):
            data = ev.get("data") or {}
            usage = data.get("usage") or {}
            stream = data.get("stream") or []

            in_tok = usage.get("inputTokens")
            out_tok = usage.get("outputTokens")

            first_chunk = None
            decode_ms = 0.0
            n_gaps = 0
            for seg in stream:
                st = seg.get("time0", seg.get("time"))
                if st is not None and first_chunk is None:
                    first_chunk = st
                dt = seg.get("dt") or []
                decode_ms += sum(dt)
                n_gaps += len(dt)

            ttft = None
            if pending_start is not None and first_chunk is not None:
                ttft = (first_chunk - pending_start) / 1000.0

            prefill = (in_tok / ttft) if (in_tok and ttft and ttft > 0) else None
            decode = (out_tok / (decode_ms / 1000.0)) if (out_tok and decode_ms > 0) else None

            note = ""
            if n_gaps < 2:
                note = f"decode unreliable (len(dt)={n_gaps})"
            if in_tok and in_tok > 15000:
                note = (note + "; " if note else "") + "large prefill (harness system prompt)"

            rows.append({
                "inputTokens": in_tok,
                "outputTokens": out_tok,
                "ttft_s": round(ttft, 3) if ttft else None,
                "prefill_tok_s": round(prefill, 1) if prefill else None,
                "decode_tok_s": round(decode, 2) if decode else None,
                "decode_window_s": round(decode_ms / 1000.0, 3) if decode_ms else None,
                "n_dt_gaps": n_gaps,
                "note": note,
            })
            pending_start = None

    return rows


def aggregate(rows):
    """Token-weighted aggregate; unweighted mean would be dominated by tiny turns."""
    good = [r for r in rows if r["n_dt_gaps"] >= 2]
    if not good:
        return None
    tin = sum(r["inputTokens"] or 0 for r in good)
    tout = sum(r["outputTokens"] or 0 for r in good)
    # weight by the natural denominator of each metric
    ttft_w = sum((r["ttft_s"] or 0) * (r["inputTokens"] or 0) for r in good)
    dwin = sum(r["decode_window_s"] or 0 for r in good)
    return {
        "requests_total": len(rows),
        "requests_usable": len(good),
        "inputTokens_sum": tin,
        "outputTokens_sum": tout,
        "weighted_prefill_tok_s": round(tin / sum(r["ttft_s"] for r in good), 1)
        if sum(r["ttft_s"] or 0 for r in good) else None,
        "weighted_ttft_s": round(ttft_w / tin, 3) if tin else None,
        "weighted_decode_tok_s": round(tout / dwin, 2) if dwin else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("home")
    ap.add_argument("--task", default="task")
    ap.add_argument("--json")
    ap.add_argument("--session", help="substring of the session dir to isolate")
    ap.add_argument("--since", help="HH:MM lower bound on session mtime")
    ap.add_argument("--until", help="HH:MM upper bound on session mtime")
    a = ap.parse_args()

    logs = find_logs(a.home, session=a.session, since=a.since, until=a.until)
    if not logs:
        sys.exit(f"no session logs found under {a.home}/sessions")

    all_rows = []
    for lg in logs:
        # Plain .jsonl files (the packed evidence logs) are read directly;
        # everything else goes through zstd.
        if lg.endswith(".jsonl"):
            with open(lg, encoding="utf-8", errors="replace") as fh:
                txt = fh.read()
        else:
            txt = read_zstd(lg)
        events = []
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        all_rows.extend(parse(events))

    agg = aggregate(all_rows)
    out = {"task": a.task, "log_files": logs, "requests": all_rows, "aggregate": agg}

    print(f"=== {a.task} ===")
    print(f"log files: {len(logs)}")
    print(f"{'#':>3} {'in_tok':>8} {'out_tok':>8} {'TTFT s':>8} "
          f"{'prefill t/s':>12} {'decode t/s':>11}  note")
    for i, r in enumerate(all_rows, 1):
        print(f"{i:>3} {r['inputTokens'] or 0:>8} {r['outputTokens'] or 0:>8} "
              f"{(r['ttft_s'] or 0):>8.2f} {(r['prefill_tok_s'] or 0):>12.1f} "
              f"{(r['decode_tok_s'] or 0):>11.2f}  {r['note']}")
    if agg:
        print()
        print(f"aggregate over {agg['requests_usable']}/{agg['requests_total']} usable requests:")
        print(f"  weighted prefill: {agg['weighted_prefill_tok_s']} tok/s")
        print(f"  weighted TTFT:    {agg['weighted_ttft_s']} s")
        print(f"  weighted decode:  {agg['weighted_decode_tok_s']} tok/s")

    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2)


if __name__ == "__main__":
    main()

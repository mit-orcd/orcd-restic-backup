#!/usr/bin/env python3
"""
dist_planner.py — Scan a directory's first-letter distribution and choose the
most efficient strategy for processing its entries in parallel.

Assumption: all entries (sub-directories / files) are of similar size, so each
entry's processing cost is ~1 and a bucket's weight is just its count.

What it does:
  1. Buckets the entries by the first letter of their name (A-Z, plus '#' for
     anything non-alphabetic).
  2. Measures how skewed that distribution is (normalized entropy, coefficient
     of variation, Gini, max/mean ratio).
  3. Picks a strategy:
        - near-uniform  -> simple equal-range / round-robin chunking
        - skewed        -> weight-balanced greedy partitioning (LPT)
     and, when a single bucket is too big to fit one worker's fair share,
     flags it for sub-splitting (by second letter) so it can't become a
     straggler.
  4. Prints a concrete per-worker assignment and the resulting imbalance.

Usage:
    python3 dist_planner.py PATH [--workers N] [--recursive] [--json]
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import math
import os
import sys
from collections import Counter, defaultdict


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

def bucket_key(name: str) -> str:
    """First-letter bucket: 'A'..'Z' for alphabetic, else '#'."""
    c = name[:1].upper()
    return c if "A" <= c <= "Z" else "#"


def scan(path: str, recursive: bool) -> Counter:
    """Return Counter of bucket -> entry count."""
    counts: Counter = Counter()
    if recursive:
        for root, dirs, files in os.walk(path):
            for n in dirs + files:
                counts[bucket_key(n)] += 1
    else:
        with os.scandir(path) as it:
            for entry in it:
                counts[bucket_key(entry.name)] += 1
    return counts


def second_letter_split(path: str, letter: str, recursive: bool) -> Counter:
    """Sub-distribution of a bucket by its SECOND character (to split a hot bucket)."""
    sub: Counter = Counter()
    letter = letter.upper()

    def add(name: str):
        if bucket_key(name) == letter:
            k = name[1:2].upper()
            sub[k if "A" <= k <= "Z" else "#"] += 1

    if recursive:
        for root, dirs, files in os.walk(path):
            for n in dirs + files:
                add(n)
    else:
        with os.scandir(path) as it:
            for entry in it:
                add(entry.name)
    return sub


# ---------------------------------------------------------------------------
# Ordering (coverage-optimal dispatch order)
# ---------------------------------------------------------------------------

def scan_dir_names(path: str, exclude: list[str]) -> dict[str, list[str]]:
    """Top-level sub-directory names bucketed by first letter, sorted within bucket.

    Mirrors the backup's discovery: only immediate sub-directories, excluding any
    name matching one of the ``exclude`` globs (e.g. ``restore*``).
    """
    buckets: dict[str, list[str]] = defaultdict(list)
    with os.scandir(path) as it:
        for entry in it:
            name = entry.name
            if any(fnmatch.fnmatch(name, pat) for pat in exclude):
                continue
            if not entry.is_dir(follow_symlinks=True):
                continue
            buckets[bucket_key(name)].append(name)
    for names in buckets.values():
        names.sort()
    return buckets


def emit_order(path: str, exclude: list[str]) -> list[str]:
    """Return all directory names in a coverage-optimal (proportional interleave) order.

    Each bucket is drained at a rate proportional to its size, so any prefix of the
    output mirrors the full first-letter distribution. Concretely, every name gets a
    "virtual time" = (rank_within_bucket + 0.5) / bucket_size in (0, 1); merging all
    names by virtual time interleaves big and small buckets evenly. This means an
    interrupted run still covers a representative slice of all owners rather than just
    the front of the alphabet. Fully deterministic.
    """
    buckets = scan_dir_names(path, exclude)
    scheduled: list[tuple[float, str, str]] = []
    for letter, names in buckets.items():
        n = len(names)
        for rank, name in enumerate(names):
            vtime = (rank + 0.5) / n
            # Tie-break by letter then name for stable, reproducible output.
            scheduled.append((vtime, letter, name))
    scheduled.sort(key=lambda t: (t[0], t[1], t[2]))
    return [name for _, _, name in scheduled]


# ---------------------------------------------------------------------------
# Skew metrics
# ---------------------------------------------------------------------------

def metrics(counts: Counter) -> dict:
    vals = [v for v in counts.values() if v > 0]
    total = sum(vals)
    k = len(vals)
    if total == 0 or k == 0:
        return {"total": 0, "buckets": 0}

    mean = total / k
    # Coefficient of variation (spread relative to mean).
    var = sum((v - mean) ** 2 for v in vals) / k
    cv = math.sqrt(var) / mean if mean else 0.0

    # Shannon entropy normalized to [0,1] (1 == perfectly uniform).
    probs = [v / total for v in vals]
    ent = -sum(p * math.log2(p) for p in probs)
    norm_ent = ent / math.log2(k) if k > 1 else 1.0

    # Gini coefficient (0 == equal, ->1 == concentrated).
    s = sorted(vals)
    cum = 0
    for i, v in enumerate(s, 1):
        cum += i * v
    gini = (2 * cum) / (k * total) - (k + 1) / k

    return {
        "total": total,
        "buckets": k,
        "mean": mean,
        "max": max(vals),
        "min": min(vals),
        "max_over_mean": max(vals) / mean,
        "cv": cv,
        "norm_entropy": norm_ent,
        "gini": gini,
    }


def classify_skew(m: dict) -> str:
    """uniform | moderate | skewed, from the metrics."""
    if m.get("total", 0) == 0:
        return "empty"
    # Normalized entropy is the primary signal; CV backs it up.
    ne, cv = m["norm_entropy"], m["cv"]
    if ne >= 0.95 and cv <= 0.25:
        return "uniform"
    if ne >= 0.80:
        return "moderate"
    return "skewed"


# ---------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------

def lpt_partition(weights: dict, workers: int) -> list[dict]:
    """
    Longest-Processing-Time-first greedy multiway partition.
    Assign each bucket (heaviest first) to the currently-least-loaded worker.
    ~4/3-optimal makespan, O(n log n).
    """
    bins = [{"load": 0, "items": []} for _ in range(workers)]
    for name, w in sorted(weights.items(), key=lambda kv: kv[1], reverse=True):
        b = min(bins, key=lambda x: x["load"])
        b["load"] += w
        b["items"].append((name, w))
    return bins


def build_plan(path: str, counts: Counter, workers: int, recursive: bool) -> dict:
    m = metrics(counts)
    skew = classify_skew(m)
    total = m.get("total", 0)
    if total == 0:
        return {"skew": skew, "metrics": m, "strategy": "nothing-to-do"}

    fair_share = total / workers

    # Effective weights. A bucket bigger than the fair share is a guaranteed
    # straggler under any letter-based scheme, so split it by second letter.
    weights: dict[str, int] = {}
    hot_splits: dict[str, dict] = {}
    for letter, c in counts.items():
        if c > fair_share * 1.10 and c > 1:  # >10% over fair share -> split
            sub = second_letter_split(path, letter, recursive)
            hot_splits[letter] = dict(sub)
            for sk, sv in sub.items():
                weights[f"{letter}{sk}"] = sv
        else:
            weights[letter] = c

    if skew == "uniform":
        strategy = "equal-range / round-robin chunking"
        rationale = ("Distribution is essentially uniform, so cheap contiguous "
                     "alphabetical chunks (or round-robin) balance the load with "
                     "zero planning overhead.")
    elif skew == "moderate":
        strategy = "weight-balanced greedy (LPT)"
        rationale = ("Mild skew: LPT on bucket weights evens out the load at "
                     "negligible cost.")
    else:
        strategy = "weight-balanced greedy (LPT) + hot-bucket sub-splitting"
        rationale = ("Heavy skew: per-letter workers would be badly imbalanced. "
                     "LPT balances weighted buckets; oversized buckets are split "
                     "by second letter so no single bucket strands a worker.")

    bins = lpt_partition(weights, workers)
    loads = [b["load"] for b in bins]
    max_load = max(loads) if loads else 0
    imbalance = max_load / (total / workers) if total else 1.0

    return {
        "skew": skew,
        "metrics": m,
        "fair_share": fair_share,
        "strategy": strategy,
        "rationale": rationale,
        "hot_splits": hot_splits,
        "assignment": [
            {"worker": i, "load": b["load"], "buckets": [n for n, _ in b["items"]]}
            for i, b in enumerate(bins)
        ],
        "max_worker_load": max_load,
        "imbalance_ratio": imbalance,
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def histogram_line(letter: str, count: int, total: int, width: int = 40) -> str:
    bar = "#" * round(width * count / total) if total else ""
    return f"  {letter:<2} {count:>7} {100*count/total:5.1f}%  {bar}"


def print_report(path: str, counts: Counter, plan: dict) -> None:
    m = plan["metrics"]
    total = m.get("total", 0)
    print(f"\nDirectory : {path}")
    print(f"Entries   : {total}   Buckets: {m.get('buckets', 0)}")
    if total == 0:
        print("Nothing to process.")
        return

    print("\nFirst-letter distribution:")
    for letter in sorted(counts, key=lambda x: (-counts[x], x)):
        print(histogram_line(letter, counts[letter], total))

    print("\nSkew metrics:")
    print(f"  normalized entropy : {m['norm_entropy']:.3f}  (1.0 = uniform)")
    print(f"  coeff. of variation: {m['cv']:.3f}")
    print(f"  gini               : {m['gini']:.3f}")
    print(f"  max/mean bucket     : {m['max_over_mean']:.2f}x")
    print(f"  classification      : {plan['skew'].upper()}")

    print(f"\nChosen strategy: {plan['strategy']}")
    print(f"  {plan['rationale']}")

    if plan.get("hot_splits"):
        print("\nHot buckets split by second letter:")
        for letter, sub in plan["hot_splits"].items():
            parts = ", ".join(f"{letter}{k}={v}" for k, v in
                              sorted(sub.items(), key=lambda kv: -kv[1]))
            print(f"  {letter}: {parts}")

    print(f"\nWorker plan (fair share ~{plan['fair_share']:.0f} entries):")
    for w in plan["assignment"]:
        print(f"  worker {w['worker']}: load={w['load']:>6}  "
              f"buckets=[{', '.join(w['buckets'])}]")
    print(f"\n  max worker load : {plan['max_worker_load']}")
    print(f"  imbalance ratio : {plan['imbalance_ratio']:.3f}  "
          f"(1.0 = perfect balance)\n")


# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="directory to scan")
    ap.add_argument("--workers", type=int, default=os.cpu_count() or 4,
                    help="number of parallel workers (default: CPU count)")
    ap.add_argument("--recursive", action="store_true",
                    help="count entries recursively instead of top-level only")
    ap.add_argument("--json", action="store_true",
                    help="emit the plan as JSON instead of a report")
    ap.add_argument("--emit-order", action="store_true",
                    help="print directory names (top-level) in coverage-optimal "
                         "processing order, one per line, then exit. Intended to feed "
                         "the backup script's dispatch order.")
    ap.add_argument("--exclude", action="append", metavar="GLOB",
                    help="glob of names to exclude (repeatable; default: 'restore*')")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.path):
        print(f"error: not a directory: {args.path}", file=sys.stderr)
        return 2
    if args.workers < 1:
        print("error: --workers must be >= 1", file=sys.stderr)
        return 2

    exclude = args.exclude if args.exclude else ["restore*"]

    # Ordering mode: emit names only and exit (consumed by restic_backup.sh).
    if args.emit_order:
        for name in emit_order(args.path, exclude):
            print(name)
        return 0

    counts = scan(args.path, args.recursive)
    plan = build_plan(args.path, counts, args.workers, args.recursive)

    if args.json:
        print(json.dumps({"path": args.path, "counts": dict(counts), **plan},
                         indent=2))
    else:
        print_report(args.path, counts, plan)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

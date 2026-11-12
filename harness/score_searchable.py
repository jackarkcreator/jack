#!/usr/bin/env python3
"""Score Make Searchable output (searchable PDF copies) against the corpus truth.

Standard library only. The text layer of each output PDF is read with a command (the Windows
build's own `Jack text {pdf}`, which uses PDFium: what a viewer's search and copy see).

  # before anything runs: record the originals
  python3 harness/score_searchable.py hash --pdfs harness/corpus --out out/originals.json

  # after the engine ran (run_engine.py --cmd "Jack.exe ocr {in} {out}" --ext .pdf --out out/ocr)
  python3 harness/score_searchable.py score --manifest harness/corpus/manifest.json --results out/ocr \
      --text-cmd "Jack.exe text {pdf}" --originals out/originals.json --pdfs harness/corpus \
      --word-scores out/word/scores.json --json out/ocr/scores.json --summary out/ocr/summary.md

Per case:
  status     text PDFs must be refused (every page already has text: nothing is written);
             scans must give a searchable copy
  recall     share of the true body words found in the text layer, in order (longest in-order match)
  anywhere   share of the true body words found anywhere in the text layer (order ignored). Search
             does not care about order; a two-column page read across both columns scores low on
             `recall` but full here
  precision  share of the text-layer words that are part of the in-order match (letterhead and
             page-number words are on the page but not in the body truth, so this is below 100%)

Gate (exit 1 when any fails):
  - every original is byte-identical afterwards (SHA-256), and nothing new appeared beside them
  - every text PDF was refused and every scan made searchable
  - per kind, mean in-order recall on the documents Save as Word converts is within --tolerance
    points of Save as Word's own recall from the same run (--word-scores), when given
  - every scan's `anywhere` recall is at least --min-anywhere (default 0.98), tables and columns
    included
"""
import argparse
import collections
import hashlib
import json
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import lcs_pairs, sidecar, tokens  # noqa: E402


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def snapshot(folder):
    return {n: sha256(os.path.join(folder, n)) for n in sorted(os.listdir(folder))
            if os.path.isfile(os.path.join(folder, n))}


def text_layer(cmd, pdf):
    parts = [p.replace("{pdf}", pdf) for p in shlex.split(cmd, posix=os.name != "nt")]
    p = subprocess.run(parts, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    if p.returncode != 0:
        raise RuntimeError(f"text command failed ({p.returncode}): {p.stderr.strip()[-200:]}")
    return p.stdout


def score_cases(manifest_path, results, text_cmd):
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    cases = []
    for d in manifest["documents"]:
        truth = tokens(d["bodyWords"])
        for v in d["variants"]:
            stem = os.path.splitext(v["file"])[0]
            sc = sidecar(results, stem)
            out = os.path.join(results, stem + ".pdf")
            want = "refused" if v["kind"] == "text" else "ok"
            case = {"case": stem, "doc": d["id"], "kind": v["kind"], "status": sc.get("status"),
                    "reason": sc.get("reason", ""), "seconds": sc.get("seconds"),
                    "word_refuses": d["expect"]["refuse"], "want": want,
                    "status_ok": sc.get("status") == want and (want == "ok") == os.path.exists(out)}
            if sc.get("status") == "ok" and os.path.exists(out):
                try:
                    got = tokens(text_layer(text_cmd, os.path.abspath(out)).split())
                except Exception as e:  # a broken probe is a failure, never a pass
                    case["status_ok"] = False
                    case["reason"] = str(e)
                    cases.append(case)
                    continue
                pairs = lcs_pairs(truth, got)
                bag = sum((collections.Counter(truth) & collections.Counter(got)).values())
                hit = {i for i, _ in pairs}
                case.update({
                    "truth_words": len(truth), "out_words": len(got),
                    "recall": round(len(pairs) / len(truth), 4) if truth else 0.0,
                    "anywhere": round(bag / len(truth), 4) if truth else 0.0,
                    "precision": round(len(pairs) / len(got), 4) if got else 0.0,
                    "missed_sample": [truth[i] for i in range(len(truth)) if i not in hit][:12],
                    "bytes_in": os.path.getsize(os.path.join(os.path.dirname(manifest_path), v["file"])),
                    "bytes_out": os.path.getsize(out),
                })
            cases.append(case)
    return cases


def totals(cases):
    by = {}
    for c in cases:
        by.setdefault(c["kind"], []).append(c)
    out = {}
    mean = lambda xs: round(sum(xs) / len(xs), 4) if xs else None
    for kind, cs in sorted(by.items()):
        scored = [c for c in cs if "recall" in c]
        convertible = [c for c in scored if not c["word_refuses"]]
        secs = [c["seconds"] for c in cs if isinstance(c.get("seconds"), (int, float))]
        out[kind] = {
            "cases": len(cs),
            "status_right": sum(1 for c in cs if c["status_ok"]),
            "recall": mean([c["recall"] for c in scored]),
            "recall_word_docs": mean([c["recall"] for c in convertible]),
            "anywhere": mean([c["anywhere"] for c in scored]),
            "precision": mean([c["precision"] for c in scored]),
            "size_ratio": mean([c["bytes_out"] / c["bytes_in"] for c in scored]),
            "seconds_mean": round(sum(secs) / len(secs), 2) if secs else None,
        }
    return out


def gate(cases, tot, originals, pdfs, word_scores, tol, min_anywhere):
    problems = []
    if originals is not None:
        now = snapshot(pdfs)
        for name, h in originals.items():
            if name not in now:
                problems.append(f"original {name} is gone")
            elif now[name] != h:
                problems.append(f"original {name} changed (SHA-256 {now[name][:12]} vs {h[:12]})")
        for name in sorted(set(now) - set(originals)):
            problems.append(f"new file beside the originals: {name}")
    for c in cases:
        if not c["status_ok"]:
            problems.append(f"{c['case']}: {c['status']} but want {c['want']} ({c['reason'][:100]})")
        if "anywhere" in c and c["anywhere"] < min_anywhere:
            problems.append(f"{c['case']}: only {c['anywhere']:.1%} of the words are searchable (min {min_anywhere:.0%})")
    if word_scores:
        for kind, t in tot.items():
            w = word_scores["totals"].get(kind)
            if kind == "text" or not w or w.get("recall") is None or t["recall_word_docs"] is None:
                continue
            if t["recall_word_docs"] < w["recall"] - tol / 100:
                problems.append(f"{kind}: in-order recall {t['recall_word_docs']:.1%} vs Save as Word {w['recall']:.1%}")
    return problems


def summary_md(engine, cases, tot, problems, word_scores):
    pct = lambda v: "n/a" if v is None else f"{v:.1%}"
    lines = [f"### Make Searchable scores: {engine}", "",
             "| Kind | Cases | Status right | Recall in order | (Save as Word docs) | Save as Word recall | Searchable anywhere | Precision | Size out/in | s/file |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for k, t in tot.items():
        w = (word_scores or {}).get("totals", {}).get(k, {}) if word_scores else {}
        size = "n/a" if t["size_ratio"] is None else f"{t['size_ratio']:.2f}x"
        lines.append(f"| {k} | {t['cases']} | {t['status_right']}/{t['cases']} | {pct(t['recall'])} | {pct(t['recall_word_docs'])} | "
                     f"{pct(w.get('recall'))} | {pct(t['anywhere'])} | {pct(t['precision'])} | "
                     f"{size} | {t['seconds_mean']} |")
    lines += ["", "| Case | Status | Recall in order | Anywhere | Precision | Missed (sample) |", "|---|---|---|---|---|---|"]
    for c in cases:
        flag = "" if c["status_ok"] else " (unexpected)"
        note = ", ".join(c.get("missed_sample", [])[:6]) if "recall" in c else c["reason"][:90]
        lines.append(f"| {c['case']} | {c['status']}{flag} | {pct(c.get('recall')) if 'recall' in c else ''} | "
                     f"{pct(c.get('anywhere')) if 'anywhere' in c else ''} | {pct(c.get('precision')) if 'precision' in c else ''} | {note.replace('|', '/')} |")
    lines += ["", "**Gate:** " + ("PASS" if not problems else "FAIL"), ""] + [f"- {p}" for p in problems]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hash", help="record SHA-256 of every file in the originals folder")
    h.add_argument("--pdfs", required=True)
    h.add_argument("--out", required=True)
    s = sub.add_parser("score", help="score the searchable copies")
    s.add_argument("--manifest", required=True)
    s.add_argument("--results", required=True, help="run_engine.py --ext .pdf output folder")
    s.add_argument("--text-cmd", required=True, help='command printing a PDF\'s text layer, with {pdf}')
    s.add_argument("--originals", help="hash file from the hash step; checks the originals are unchanged")
    s.add_argument("--pdfs", help="the originals folder (with --originals)")
    s.add_argument("--word-scores", help="score.py --json output of Save as Word on the same corpus")
    s.add_argument("--tolerance", type=float, default=1.0)
    s.add_argument("--min-anywhere", type=float, default=0.98)
    s.add_argument("--engine", default="")
    s.add_argument("--json")
    s.add_argument("--summary")
    a = ap.parse_args()

    if a.cmd == "hash":
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(snapshot(a.pdfs), f, indent=2)
        print(f"recorded {len(snapshot(a.pdfs))} files")
        return 0

    if a.originals and not a.pdfs:
        ap.error("--originals needs --pdfs")
    originals = None
    if a.originals:
        with open(a.originals, encoding="utf-8") as f:
            originals = json.load(f)
    word_scores = None
    if a.word_scores and os.path.exists(a.word_scores):
        with open(a.word_scores, encoding="utf-8") as f:
            word_scores = json.load(f)
    cases = score_cases(a.manifest, a.results, a.text_cmd)
    tot = totals(cases)
    problems = gate(cases, tot, originals, a.pdfs, word_scores, a.tolerance, a.min_anywhere)
    if a.word_scores and word_scores is None:
        problems.append(f"Save as Word scores not found at {a.word_scores}")
    report = {"engine": a.engine, "totals": tot, "cases": cases, "gate": problems}
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
    md = summary_md(a.engine or a.results, cases, tot, problems, word_scores)
    if a.summary:
        with open(a.summary, "w", encoding="utf-8") as f:
            f.write(md)
    print(md)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

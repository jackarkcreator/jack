#!/usr/bin/env python3
"""Score Save as Word output against the corpus truth, or against another engine's output.

Standard library only, so it runs unchanged on macOS and Windows.

  # synthetic corpus, ground truth from the manifest
  python3 harness/score.py --manifest harness/corpus/manifest.json --results out/mac \
      --json out/mac.json --summary out/mac.md

  # gate a candidate (e.g. the Windows engine) against a recorded baseline
  python3 harness/score.py --manifest harness/corpus/manifest.json --results out/win \
      --baseline harness/baseline-mac.json --json out/win.json --summary out/win.md

  # private corpus: no truth, compare to a reference engine's .docx files instead
  python3 harness/score.py --reference out/private-mac --results out/private-win --json out/p.json

The results folder holds, for every input file <stem>.pdf, the engine's <stem>.docx (when it made
one) and <stem>.json: {"status": "ok" | "refused" | "failed", "reason": "...", "seconds": 1.2}.

Metrics, per case:
  recall     share of the true words found in the .docx, in order (longest in-order match)
  precision  share of the .docx words that are part of that match
  misread    .docx words the document does not contain at all (OCR misreads)
  caught     share of misreads highlighted for checking (honesty)
  misplaced  real words in the wrong order (merged lines, crossed columns); reading twice cannot catch these
  false_flag share of all .docx words highlighted although they are right
  features   pages, checkboxes (and ticked), signature placeholders, letterhead, page-number footer
  baseSize   body text size in points; the gate fails if it differs from the baseline by more than 0.5 pt
"""
import argparse
import json
import os
import re
import sys
import unicodedata
import zipfile
import xml.etree.ElementTree as ET

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
W14 = "{http://schemas.microsoft.com/office/word/2010/wordml}"
SIGNATURE_NOTE = "signed on executed original"
QUOTES = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-"})


def norm(token):
    t = unicodedata.normalize("NFKC", token).translate(QUOTES).lower()
    t = t.strip(".,;:!?()[]{}\"'")
    return t if any(c.isalnum() for c in t) else ""


def tokens(words):
    out = []
    for w in words:
        n = norm(w)
        if n:
            out.append(n)
    return out


def lcs_pairs(a, b):
    """Index pairs (i, j) of the longest in-order match between lists a and b."""
    n, m = len(a), len(b)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        ai, row, nxt = a[i], dp[i], dp[i + 1]
        for j in range(m - 1, -1, -1):
            row[j] = nxt[j + 1] + 1 if ai == b[j] else max(nxt[j], row[j + 1])
    pairs, i, j = [], 0, 0
    while i < n and j < m:
        if a[i] == b[j]:
            pairs.append((i, j)); i += 1; j += 1
        elif dp[i + 1][j] >= dp[i][j + 1]:
            i += 1
        else:
            j += 1
    return pairs


def read_docx(path):
    """Body words (with a flag for highlighted ones) and layout features of a .docx."""
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        doc = ET.fromstring(z.read("word/document.xml"))
        footers = [z.read(n).decode("utf-8", "replace") for n in names if re.match(r"word/footer\d*\.xml$", n)]
        styles = z.read("word/styles.xml").decode("utf-8", "replace") if "word/styles.xml" in names else ""
        headers = [z.read(n).decode("utf-8", "replace") for n in names if re.match(r"word/header\d*\.xml$", n)]
    body = doc.find(W + "body")
    words, flags, signatures = [], [], 0
    for p in body.iter(W + "p"):
        text = "".join(t.text or "" for t in p.iter(W + "t"))
        if SIGNATURE_NOTE in text.lower():
            signatures += 1
            continue
        chars = []  # (char, highlighted)
        for r in p.iter(W + "r"):
            rpr = r.find(W + "rPr")
            hl = rpr is not None and rpr.find(W + "highlight") is not None
            for child in r:
                if child.tag == W + "t":
                    chars += [(c, hl) for c in (child.text or "")]
                elif child.tag in (W + "tab", W + "br", W + "cr"):
                    chars.append((" ", False))
        chars.append((" ", False))
        cur, curhl = "", False
        for c, hl in chars:
            if c.isspace():
                if cur:
                    words.append(cur); flags.append(curhl)
                cur, curhl = "", False
            else:
                cur += c; curhl = curhl or hl
    # drop tokens that normalise to nothing (checkbox glyphs, bullets), keeping flags aligned
    kept = [(norm(w), f) for w, f in zip(words, flags) if norm(w)]
    breaks = sum(1 for _ in body.iter(W + "pageBreakBefore")) + \
        sum(1 for b in body.iter(W + "br") if b.get(W + "type") == "page")
    boxes = list(doc.iter(W14 + "checkbox"))
    ticked = sum(1 for b in boxes for c in b.iter(W14 + "checked") if c.get(W14 + "val") in ("1", "true"))
    return {
        "words": [w for w, _ in kept],
        "flags": [f for _, f in kept],
        "pages": 1 + breaks,
        "checkboxes": len(boxes),
        "checked": ticked,
        "signatures": signatures,
        "letterhead": any("<w:drawing" in h or "<pic:" in h for h in headers),
        "pageNumbers": any("NUMPAGES" in f for f in footers),
        "baseSize": base_size(styles),
    }


def base_size(styles):
    """Body text size in points: the document default run size (half-points in w:sz)."""
    m = re.search(r"<w:docDefaults>.*?<w:sz w:val=\"(\d+)\"", styles, re.S)
    return int(m.group(1)) / 2 if m else None


def sidecar(results, stem):
    p = os.path.join(results, stem + ".json")
    if not os.path.exists(p):
        return {"status": "missing", "reason": "no result file", "seconds": None}
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def word_metrics(truth, out_words, out_flags):
    pairs = lcs_pairs(truth, out_words)
    matched_out = {j for _, j in pairs}
    wrong = [j for j in range(len(out_words)) if j not in matched_out]
    vocab = set(truth)
    # A misread is a word the document does not contain at all: highlighting should catch it.
    # A misplaced word is a real word out of order (lines merged, columns crossed): reading
    # twice cannot see it, so it is counted apart and drags recall down instead.
    misread = [j for j in wrong if out_words[j] not in vocab]
    misplaced = [j for j in wrong if out_words[j] in vocab]
    flagged = [j for j, f in enumerate(out_flags) if f]
    caught = [j for j in misread if out_flags[j]]
    false_flags = [j for j in flagged if j in matched_out]
    return {
        "truth_words": len(truth),
        "out_words": len(out_words),
        "recall": round(len(pairs) / len(truth), 4) if truth else 0.0,
        "precision": round(len(pairs) / len(out_words), 4) if out_words else 0.0,
        "wrong": len(wrong),
        "misread": len(misread),
        "misplaced": len(misplaced),
        "flagged": len(flagged),
        "caught": len(caught),
        "false_flags": len(false_flags),
        "missed_sample": [truth[i] for i in range(len(truth)) if i not in {a for a, _ in pairs}][:12],
        "misread_sample": [out_words[j] + ("*" if out_flags[j] else "") for j in misread][:12],
    }


def score_manifest(manifest_path, results):
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    cases = []
    for d in manifest["documents"]:
        truth = tokens(d["bodyWords"])
        exp = d["expect"]
        for v in d["variants"]:
            stem = os.path.splitext(v["file"])[0]
            sc = sidecar(results, stem)
            case = {"case": stem, "doc": d["id"], "kind": v["kind"], "status": sc.get("status"),
                    "reason": sc.get("reason", ""), "seconds": sc.get("seconds"),
                    "expect_refuse": exp["refuse"]}
            if exp["refuse"]:
                case["refusal_ok"] = sc.get("status") == "refused"
            else:
                case["refusal_ok"] = sc.get("status") == "ok"
                docx = os.path.join(results, stem + ".docx")
                if sc.get("status") == "ok" and os.path.exists(docx):
                    got = read_docx(docx)
                    case.update(word_metrics(truth, got["words"], got["flags"]))
                    case["features"] = {
                        "pages": got["pages"] == exp["pages"],
                        "checkboxes": got["checkboxes"] == exp["checkboxes"],
                        "checked": got["checked"] == exp["checked"],
                        "signatures": got["signatures"] == exp["signatures"],
                        "letterhead": got["letterhead"] == exp["letterhead"],
                        "pageNumbers": got["pageNumbers"] == exp["pageNumbers"],
                    }
                    case["found"] = {k: got[k] for k in ("pages", "checkboxes", "checked", "signatures", "letterhead", "pageNumbers", "baseSize")}
            cases.append(case)
    return cases


def score_reference(reference, results):
    cases = []
    for name in sorted(os.listdir(reference)):
        if not name.endswith(".json"):
            continue
        stem = name[:-5]
        ref, sc = sidecar(reference, stem), sidecar(results, stem)
        case = {"case": stem, "doc": stem, "kind": "private", "status": sc.get("status"),
                "reason": sc.get("reason", ""), "seconds": sc.get("seconds"),
                "reference_status": ref.get("status"), "expect_refuse": ref.get("status") == "refused"}
        case["refusal_ok"] = sc.get("status") == ref.get("status")
        rd, cd = os.path.join(reference, stem + ".docx"), os.path.join(results, stem + ".docx")
        if ref.get("status") == "ok" and sc.get("status") == "ok" and os.path.exists(rd) and os.path.exists(cd):
            r, c = read_docx(rd), read_docx(cd)
            case.update(word_metrics(r["words"], c["words"], c["flags"]))
            case["features"] = {k: r[k] == c[k] for k in ("pages", "checkboxes", "checked", "signatures", "letterhead", "pageNumbers")}
        cases.append(case)
    return cases


def totals(cases):
    by = {}
    for c in cases:
        by.setdefault(c["kind"], []).append(c)
    out = {}
    for kind, cs in sorted(by.items()):
        scored = [c for c in cs if "recall" in c]
        misread = sum(c["misread"] for c in scored)
        words = sum(c["out_words"] for c in scored)
        secs = [c["seconds"] for c in cs if isinstance(c.get("seconds"), (int, float))]
        feats = [v for c in scored for v in c["features"].values()]
        out[kind] = {
            "cases": len(cs),
            "refusals_right": sum(1 for c in cs if c["refusal_ok"]),
            "recall": round(sum(c["recall"] for c in scored) / len(scored), 4) if scored else None,
            "precision": round(sum(c["precision"] for c in scored) / len(scored), 4) if scored else None,
            "misread_words": misread,
            "misplaced_words": sum(c["misplaced"] for c in scored),
            "caught": round(sum(c["caught"] for c in scored) / misread, 4) if misread else 1.0,
            "false_flag": round(sum(c["false_flags"] for c in scored) / words, 4) if words else 0.0,
            "features_right": f"{sum(feats)}/{len(feats)}",
            "seconds_mean": round(sum(secs) / len(secs), 2) if secs else None,
        }
    return out


def gate(cases, tot, baseline, tol):
    """Phase 1 exit criteria against a baseline run: same refusals per case, recall within `tol`
    points per case and per kind, honesty (caught) not lower per kind, no feature lost."""
    problems = []
    base_cases = {c["case"]: c for c in baseline["cases"]}
    for c in cases:
        b = base_cases.get(c["case"])
        if not b:
            continue
        if c["status"] != b["status"]:
            problems.append(f"{c['case']}: status {c['status']} but baseline {b['status']}")
            continue
        if "recall" in c and "recall" in b and c["recall"] < b["recall"] - tol / 100:
            problems.append(f"{c['case']}: recall {c['recall']:.1%} vs baseline {b['recall']:.1%}")
        for k, ok in c.get("features", {}).items():
            if b.get("features", {}).get(k) and not ok:
                problems.append(f"{c['case']}: lost feature '{k}'")
        # Body text size must match the reference engine's (a wrong size reflows the whole document).
        cs, bs = (c.get("found") or {}).get("baseSize"), (b.get("found") or {}).get("baseSize")
        if cs is not None and bs is not None and abs(cs - bs) > 0.5:
            problems.append(f"{c['case']}: body text {cs}pt vs baseline {bs}pt")
    for kind, t in tot.items():
        b = baseline["totals"].get(kind)
        if not b or t["recall"] is None or b["recall"] is None:
            continue
        if t["recall"] < b["recall"] - tol / 100:
            problems.append(f"{kind}: mean recall {t['recall']:.1%} vs baseline {b['recall']:.1%}")
        if t["caught"] < b["caught"] - tol / 100:
            problems.append(f"{kind}: caught {t['caught']:.1%} of misread words vs baseline {b['caught']:.1%}")
    return problems


def summary_md(engine, cases, tot, problems, gated):
    lines = [f"### Save as Word scores: {engine}", "",
             "| Kind | Cases | Refusals right | Recall | Precision | Misread | Caught | Misplaced | False flags | Features | s/file |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    pct = lambda v: "n/a" if v is None else f"{v:.1%}"
    for k, t in tot.items():
        lines.append(f"| {k} | {t['cases']} | {t['refusals_right']}/{t['cases']} | {pct(t['recall'])} | {pct(t['precision'])} | "
                     f"{t['misread_words']} | {pct(t['caught'])} | {t['misplaced_words']} | {pct(t['false_flag'])} | {t['features_right']} | {t['seconds_mean']} |")
    lines += ["", "| Case | Status | Recall | Misread (caught) | Misplaced | Features off | Note |", "|---|---|---|---|---|---|---|"]
    for c in cases:
        off = ", ".join(k for k, v in c.get("features", {}).items() if not v)
        note = c["reason"][:90] if c["status"] != "ok" else ", ".join(c.get("missed_sample", [])[:5])
        rec = pct(c.get("recall")) if "recall" in c else ""
        wr = f"{c['misread']} ({c['caught']})" if "wrong" in c else ""
        mp = str(c["misplaced"]) if "wrong" in c else ""
        flag = "" if c["refusal_ok"] else " (unexpected)"
        lines.append(f"| {c['case']} | {c['status']}{flag} | {rec} | {wr} | {mp} | {off} | {note.replace('|', '/')} |")
    if gated:
        lines += ["", "**Gate:** " + ("PASS" if not problems else "FAIL"), ""] + [f"- {p}" for p in problems]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--manifest", help="corpus manifest.json (ground truth)")
    src.add_argument("--reference", help="folder of a reference engine's results (private corpus)")
    ap.add_argument("--results", required=True, help="folder of the engine's .docx and .json results")
    ap.add_argument("--engine", default="", help="label for the report")
    ap.add_argument("--baseline", help="baseline scores JSON to gate against")
    ap.add_argument("--tolerance", type=float, default=1.0, help="allowed drop in points (default 1.0)")
    ap.add_argument("--json", help="write scores JSON here")
    ap.add_argument("--summary", help="write a Markdown summary here")
    a = ap.parse_args()

    cases = score_manifest(a.manifest, a.results) if a.manifest else score_reference(a.reference, a.results)
    tot = totals(cases)
    problems = []
    if a.baseline:
        with open(a.baseline, encoding="utf-8") as f:
            problems = gate(cases, tot, json.load(f), a.tolerance)
    report = {"engine": a.engine, "totals": tot, "cases": cases, "gate": problems if a.baseline else None}
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
    md = summary_md(a.engine or a.results, cases, tot, problems, bool(a.baseline))
    if a.summary:
        with open(a.summary, "w", encoding="utf-8") as f:
            f.write(md)
    print(md)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

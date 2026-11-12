#!/usr/bin/env python3
"""Run a Save as Word engine over every PDF in a folder and record results for score.py.

  # Mac baseline: the installed, notarized Jack (headless self-test hook, no window opens)
  python3 harness/run_engine.py --mac /Applications/Jack.app --pdfs harness/corpus --out out/mac

  # any command-line engine (the Windows CLI later); {in} and {out} are substituted
  python3 harness/run_engine.py --cmd "Jack.exe word {in} {out}" --pdfs harness/corpus --out out/win

  # Mac, also dumping what the engine read (page images, both OCR readings) for replay
  python3 harness/run_engine.py --mac JackDev.app --pdfs harness/corpus --out out/mac --dump out/dump

For each <stem>.pdf it writes <stem>.docx (when the engine made one), <stem>.json with
{"status", "reason", "seconds", "engine"} and <stem>.log with the engine's own output.

Command engines report through their exit code: 0 = made the .docx, 3 = refused (reason on a line
starting "REFUSED:"), anything else = failed. The Mac self-test only prints its message, so a
refusal is recognised by Jack's refusal wording ("won't make it").
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import time


def classify_mac(code, text, docx):
    if code == 0 and os.path.exists(docx):
        return "ok", ""
    reason = ""
    for line in text.splitlines():
        if line.startswith("FAILED:"):
            reason = line[len("FAILED:"):].strip()
    low = reason.replace("’", "'").lower()
    return ("refused" if "won't make it" in low else "failed"), reason or text.strip()[-300:]


def classify_cmd(code, text, docx):
    if code == 0 and os.path.exists(docx):
        return "ok", ""
    reason = next((l[len("REFUSED:"):].strip() for l in text.splitlines() if l.startswith("REFUSED:")), "")
    if code == 3:
        return "refused", reason
    return "failed", reason or text.strip()[-300:]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    eng = ap.add_mutually_exclusive_group(required=True)
    eng.add_argument("--mac", help="path to Jack.app")
    eng.add_argument("--cmd", help='command template with {in} and {out}')
    ap.add_argument("--pdfs", required=True, help="folder of PDFs (not recursive)")
    ap.add_argument("--out", required=True, help="results folder")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--only", help="substring filter on file names")
    ap.add_argument("--dump", help="with --mac: folder for the engine's input dump (JACK_WORD_DUMP), one subfolder per PDF")
    a = ap.parse_args()
    if a.dump and not a.mac:
        ap.error("--dump needs --mac")

    os.makedirs(a.out, exist_ok=True)
    pdfs = sorted(f for f in os.listdir(a.pdfs) if f.lower().endswith(".pdf") and (not a.only or a.only in f))
    if not pdfs:
        print("no PDFs found", file=sys.stderr)
        return 2
    label = a.mac or a.cmd
    if a.mac:
        exe = os.path.join(a.mac, "Contents", "MacOS", "Jack")
        version = subprocess.run(["defaults", "read", os.path.join(os.path.abspath(a.mac), "Contents", "Info"),
                                  "CFBundleShortVersionString"], capture_output=True, text=True).stdout.strip()
        label = f"Jack {version} (macOS)"
    for name in pdfs:
        stem = os.path.splitext(name)[0]
        src = os.path.abspath(os.path.join(a.pdfs, name))
        docx = os.path.abspath(os.path.join(a.out, stem + ".docx"))
        if os.path.exists(docx):
            os.remove(docx)
        t0 = time.time()
        try:
            if a.mac:
                env = dict(os.environ, JACK_WORD_SELFTEST=docx, JACK_WORD_SELFTEST_PDF=src)
                env.pop("JACK_WORD_DUMP", None)
                if a.dump:
                    env["JACK_WORD_DUMP"] = os.path.abspath(os.path.join(a.dump, stem))
                p = subprocess.run([exe], env=env, capture_output=True, text=True, timeout=a.timeout)
            else:
                cmd = [part.replace("{in}", src).replace("{out}", docx) for part in shlex.split(a.cmd, posix=os.name != "nt")]
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=a.timeout)
            code, text = p.returncode, (p.stdout or "") + (p.stderr or "")
        except subprocess.TimeoutExpired:
            code, text = -1, f"timed out after {a.timeout}s"
        secs = round(time.time() - t0, 2)
        status, reason = (classify_mac if a.mac else classify_cmd)(code, text, docx)
        with open(os.path.join(a.out, stem + ".log"), "w", encoding="utf-8") as f:
            f.write(text)
        with open(os.path.join(a.out, stem + ".json"), "w", encoding="utf-8") as f:
            json.dump({"status": status, "reason": reason, "seconds": secs, "engine": label}, f, indent=2, ensure_ascii=False)
        print(f"{status:8} {secs:6.1f}s  {name}" + (f"  ({reason[:80]})" if reason else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

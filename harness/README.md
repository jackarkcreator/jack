# Save as Word test harness

One corpus and one scoring script for every Save as Word engine: the shipping Mac engine
(`Sources/WordExportEngine.swift`) and the Windows port. The Windows port is ready only when it scores within 1 point of the Mac on the same files.

## Files
| File | What it does |
|---|---|
| `make_corpus.swift` | Builds the synthetic corpus in `corpus/`. Each made-up document comes as a text PDF and a 200 DPI skewed, noisy scan; some also get a rougher 150 DPI scan. `manifest.json` holds the true body words in reading order and what the converter should do (refuse or not, pages, checkboxes, signatures, letterhead, page numbers). |
| `run_engine.py` | Runs an engine over a folder of PDFs and writes `<stem>.docx`, `<stem>.json` (status, reason, seconds) and `<stem>.log`. Use `--mac` for Jack.app (headless self-test, no window) or `--cmd` for any command-line engine. |
| `score.py` | Scores the results. It reports recall and precision of words in order, honesty (wrong words that were highlighted), false highlights, refusals and layout features. With `--baseline` it gates a candidate against a recorded run. Standard-library Python only. |
| `baseline-mac.json` | Scores of the shipping Mac engine (Jack 3.5.1, notarized) on this corpus: the bar for the Windows port. Re-record it from the notarized build on every engine release. |

## Run it
```bash
swift harness/make_corpus.swift harness/corpus          # only when the documents change
python3 harness/run_engine.py --mac /Applications/Jack.app --pdfs harness/corpus --out /tmp/jack-h/mac
python3 harness/score.py --manifest harness/corpus/manifest.json --results /tmp/jack-h/mac --summary /tmp/jack-h/mac.md
```
Gate another engine against the Mac:
```bash
python3 harness/score.py --manifest harness/corpus/manifest.json --results <its results> \
    --baseline harness/baseline-mac.json --tolerance 1.0
```
The exit code is 1 if any of these happens:
- a refusal differs from the Mac's
- recall drops more than 1 point on any file or kind
- a kind has more than 2 misread words left unhighlighted beyond the Mac's count
- body text size differs from the Mac's by more than 0.5 pt
- a layout feature the Mac got right is lost

## Replay: the Windows engine on the Mac's own inputs
`--dump DIR` (with `--mac`) makes the Mac engine write what it read for every PDF: page size, scan
test, text layer, the gray page image before and after deskew, both Vision readings in Vision's own
order, and the letterhead crop (`JACK_WORD_DUMP`, debug only; the .docx is unchanged). The C#
engine replays that with no OCR and no PDFium, so any difference is a porting bug:
```bash
python3 harness/run_engine.py --mac JackDev.app --pdfs harness/corpus --out /tmp/jack-h/mac --dump /tmp/jack-h/dump
dotnet build win/Jack.Cli -r osx-arm64 -c Release -o /tmp/jack-h/cli
python3 harness/run_engine.py --cmd "dotnet /tmp/jack-h/cli/Jack.dll word {in} {out} --replay /tmp/jack-h/dump" \
    --pdfs harness/corpus --out /tmp/jack-h/replay
python3 harness/score.py --reference /tmp/jack-h/mac --results /tmp/jack-h/replay
```
`--own-rotation` deskews with the Windows rotation instead of the Mac's pixels. Each log ends with
the replay checks (line order against the Mac's, image hashes); any warning means the run diverged.

## Command-line engine contract
`--cmd "<exe> word {in} {out}"`:
- exit **0** and write `{out}`: converted
- exit **3** and print `REFUSED: <reason>`: refused (tables, columns)
- anything else: failed

## Real documents (private corpus)
Real office PDFs never go in this repository. They live outside it, for example:
```
~/Ccode/jack-corpus-private/
  pdfs/          the real PDFs
  results-mac/   run_engine.py --mac output (the reference)
  results-win/   run_engine.py --cmd output from the Windows build
```
Real files have no ground truth, so the Windows engine is scored against the Mac's output on the same file:
```bash
python3 harness/score.py --reference ~/Ccode/jack-corpus-private/results-mac --results ~/Ccode/jack-corpus-private/results-win
```
Only the totals from the private corpus may be quoted outside it (in commits, release notes or issues). File names and words stay private.

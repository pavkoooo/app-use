# Benchmark: app-use vs screenshot paths

**Target:** macOS Calculator  
**Host:** Darwin 22.6.0, x86_64 (macOS Intel)  
**Measured:** 2026-10-25T14:16:45Z  
**Harness:** `python3 bench/compare-calculator.py`  
**Raw local JSON:** `bench/out/compare-calculator.json` (gitignored; regenerate with the harness)

## Method

1. **app-use (AX)** — start `skill/start.sh`, register Calculator, `GET /snapshot`, score whether each required keypad label appears in AX `texts`. Then clear, click digits `1`…`5` by stable `nodeId`, and require the display read-back to match after each click.
2. **Screenshot + local OCR** — `screencapture` of the desktop, then macOS **Vision** OCR (`bench/ocr-screenshot.swift`). Score the same label set. This is **on-device OCR**, not a cloud VLM computer-use agent.
3. **Cloud VLM / pixel click** — **not measured** on this host (no API call). Listed qualitatively only. We do not invent accuracy numbers.

Required label set: `0–9`, `+`, `−`, `×`, `÷`, `=`.

## Results (this run)

| Metric | app-use (AX) | Screenshot + Vision OCR | Typical screenshot → cloud VLM → pixel click |
|--------|--------------|-------------------------|-----------------------------------------------|
| Keypad label recall | **15/15 (100%)** | Substring **11/15 (73%)**; strict token match **1/15 (7%)** — full-screen OCR noise; operators mostly missed | Not measured |
| Click / act success | **5/5 (100%)** digit clicks with display read-back `1`→`12345` | No stable control ids — cannot act from OCR alone | Pixel/box guess; fragile under layout change |
| Median act latency | **~4.9 s** per click+settle+read (localhost AX) | Screenshot **~1.3 s** + OCR **~10.6 s** (read-only) | Dominated by model + network |
| Needs vision model? | **No** | No (local OCR) | **Yes** |
| Stable node ids? | **Yes** | No | No |

### app-use detail

| Step | Value |
|------|--------|
| AX read wall time | 5402 ms |
| Register session | 17 ms |
| Click success rate | 1.0 |
| Median click+read-back | 4861 ms |
| Vision model required | false |

### OCR detail

| Step | Value |
|------|--------|
| Engine | `macos-vision-ocr` |
| Label recall (substring in joined OCR lines) | 0.7333 (miss: `+`, `−`, `÷`, `=`) |
| Label recall (strict token / exact line) | 0.0667 (only `6` as a clean token — digits otherwise only appear inside other strings) |
| Screenshot wall time | 1338 ms |
| OCR wall time | 10647 ms |

Full-screen OCR also picks up unrelated desktop chrome (menu bar, viewer HTML path, etc.), so digit “hits” can be assisted by other on-screen numerals. AX scores only the Calculator accessibility tree.

## Reproduce

```bash
./skill/start.sh
python3 bench/compare-calculator.py
# writes bench/out/compare-calculator.json
```

Optional: compile the OCR helper once for faster runs:

```bash
xcrun --sdk macosx swiftc -O -framework Vision -framework AppKit \
  -o bench/ocr-screenshot bench/ocr-screenshot.swift
```

## What this does *not* claim

- It does not rank commercial computer-use products.
- It does not assign a numeric accuracy to GPT-4V / Claude computer-use / similar without running them.
- Apps without an Accessibility tree remain out of scope for app-use (see README boundaries).

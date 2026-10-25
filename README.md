# app-use

**Read any app’s UI as structured text. Operate it with the same protocol.**

No screenshots. No vision / multimodal model. app-use walks the macOS Accessibility (AX) tree and turns windows, menus, and controls into a stable JSON tree an AI can reason over — then click, type, and verify through the same ids.

---

## Two cores

### 1. Read — GUI → structured text protocol

Attach a target app. The reader emits a snapshot:

- `app`, `capturedAt`
- tree of nodes: `{ id, role, frame, texts, children }`

`id` stays stable while the tree shape stays stable, so an agent can plan against labels and act against ids. Schemas live in `protocol/`.

This is **not** OCR on pixels. Copy comes from the runtime GUI / Accessibility tree (including embedded web content when the app exposes it).

### 2. Write / control — same protocol, plus human usage recording

- **Click** a node (`action: click`, `nodeId`)
- **Write** into a field (`action: write`, `nodeId`, `text`)
- **Record** what a human fronts and which controls they use (`usage.recorded`)

A local notification broker fans out `gui.changed` so a viewer or agent can react after each act.

---

## Quick start (zero toolchain)

**Platform today:** macOS **Intel (x86_64) first**. Apple Silicon: install Rosetta for the shipped binary, or use the optional build path below.

```bash
git clone https://github.com/pavkoooo/app-use.git
cd app-use
./skill/start.sh
```

Then open `dev/viewer/index.html`. Grant **Accessibility** to the host running the skill (Terminal / Cursor):  
System Settings → Privacy & Security → Accessibility.

Smoke demo:

```bash
./test/read-calculator.sh
./test/click-calculator.sh
```

### What you need (runtime, not “dev deps”)

| Need | Why |
|------|-----|
| macOS | Shipped reader is macOS Intel |
| `/usr/bin/python3` | Broker uses stdlib only (ships with macOS) |
| Prebuilt `platforms/macos/intel/gui-reader/gui-reader` | Included in the repo — **no Xcode/Swift compile** for normal use |
| Accessibility permission | System authorization so AX can read/click |

**Optional developer path** (rebuild from `main.swift`):

```bash
APP_USE_BUILD=1 ./skill/start.sh   # needs Xcode Command Line Tools
```

Agent skill entry: [`skill/SKILL.md`](skill/SKILL.md).

---

## Demo

End-to-end recording (start skill → viewer/protocol → read Calculator → click → read back):

[docs/demo/app-use-demo.mp4](docs/demo/app-use-demo.mp4)

Re-record locally:

```bash
./docs/demo/record-demo.sh
```

---

## How it compares (measured on this repo’s Calculator bench)

Full methodology and raw JSON: [`docs/benchmark.md`](docs/benchmark.md). Re-run:

```bash
python3 bench/compare-calculator.py
```

| Dimension | app-use (AX protocol) | Screenshot + local OCR (Vision) | Typical screenshot → cloud VLM → pixel click |
|-----------|----------------------|----------------------------------|-----------------------------------------------|
| Label read completeness (Calculator keypad) | **15/15 (100%)** | Substring 11/15; strict token **1/15** | Not measured (needs external VLM) |
| Control locate + click success | **5/5 (100%)** stable `nodeId` + display read-back | No actionable ids | Pixel/box guess; no AX ids |
| Latency (this host) | Read ~5.4 s; click+read ~4.9 s median | Shot ~1.3 s + OCR ~10.6 s | Network + model |
| Cost | No vision API | On-device OCR | Vision/API tokens |
| Needs vision model? | **No** | No (OCR only) | **Yes** |

Numbers from `bench/compare-calculator.py` on 2026-10-25 — details in [`docs/benchmark.md`](docs/benchmark.md). We do **not** invent cloud-VLM accuracy scores.

---

## Layout

```
skill/           # start.sh + SKILL.md (install / one-shot run)
framework/       # notification broker + attach hook
platforms/macos/intel/gui-reader/  # prebuilt binary + source
protocol/        # JSON schemas
dev/viewer/      # HTML viewer (snapshots are gitignored)
test/            # regression scripts
bench/           # reproducible compare harness
docs/            # benchmark notes + demo video
```

---

## Capability boundaries

**Works when** the app exposes an Accessibility tree (AppKit, many Electron/Java/Flutter surfaces, menus, Dock, etc.).

**Hard limits**

- Pure graphics overlays with no AX (e.g. some Mission Control / Launchpad layers)
- Apps that intentionally expose no operable tree
- Non-macOS targets — folders exist; readers not shipped yet

Prefer fixing the generic reader/broker when something fails — do not add one-off bypass scripts.

---

## 中文摘要

**app-use** 用系统 Accessibility 把任意 macOS 应用界面读成给 AI 用的结构化文本协议，并用同一套协议点击/输入；可记录人类操作。不依赖截图或多模态模型。当前优先 **macOS Intel**；克隆仓库后 `./skill/start.sh` 即可（自带预编译 `gui-reader` + Python 标准库 broker）。需授予辅助功能权限。对比数据与 Demo 见 `docs/benchmark.md` 与 `docs/demo/`。

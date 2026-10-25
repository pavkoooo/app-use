---
name: app-use
description: >-
  Read and operate macOS app UIs through Accessibility — structured text protocol,
  no screenshots or vision models. Use when an agent must inspect or click real
  application controls, run the local broker, or record human usage.
---

# app-use

Turn any Accessibility-exposed macOS app into a structured GUI tree an AI can read and act on. Same protocol for **read** (snapshot) and **write** (click / type). No multimodal model required.

## Install (zero toolchain)

1. Clone https://github.com/pavkoooo/app-use (full clone — includes the prebuilt `gui-reader`).
2. Copy or symlink this `skill/` folder into your Agent Skills path, **or** open the repo and call `skill/start.sh` directly.
3. Grant **Accessibility** to the host that runs the skill (Terminal, Cursor, etc.):
   System Settings → Privacy & Security → Accessibility → enable the host app.
4. Start:

```bash
./skill/start.sh
```

That starts the notification broker on `http://127.0.0.1:47653`, attaches the shipped reader, and begins usage recording. Open `dev/viewer/index.html` to see the live protocol tree.

**Runtime assumptions (not “dev dependencies”):**

| Need | Notes |
|------|--------|
| macOS | Reader package is **macOS Intel (x86_64)** first. Apple Silicon: install Rosetta, or `APP_USE_BUILD=1` (optional developer path). |
| `/usr/bin/python3` | System Python 3 — ships with macOS. Broker uses only the stdlib. |
| Accessibility | System permission; required for AX reads/clicks. |
| Prebuilt `platforms/macos/intel/gui-reader/gui-reader` | Shipped in the repo. No Xcode/Swift compile for normal use. |

**Optional developer path:** `APP_USE_BUILD=1 ./skill/start.sh` recompiles `main.swift` (needs Xcode Command Line Tools).

## Demo smoke (Calculator)

```bash
./skill/start.sh
./test/read-calculator.sh    # structured read
./test/click-calculator.sh   # click "1", read display back
```

Register another app from the viewer or via the broker listen/register flow (see README).

## Protocol (agent-facing)

- **Read:** GUI snapshot JSON (`protocol/gui-snapshot.schema.json`) — `app`, `capturedAt`, tree of `{id, role, frame, texts, children}`.
- **Write:** `POST /perform` with `action: click|write` and `nodeId` from the snapshot (`protocol/gui-perform.schema.json`).
- **Notify:** `gui.changed` / `usage.recorded` over the broker (`protocol/notifications.schema.json`).

Prefer fixing the generic reader/broker when an app fails — do not add one-off bypass scripts.

## Stop

Kill the broker listening on port `47653`, or re-run `./skill/start.sh` (it stops the previous instance first).

#!/usr/bin/env python3
"""Reproducible Calculator compare: app-use (AX) vs local screenshot OCR.

Measures on this machine only. Does not call cloud VLMs and does not invent
their accuracy — those rows are marked methodology-only in the report.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "bench" / "out"
REQUIRED_LABELS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "−", "×", "÷", "="]
BASE = "http://127.0.0.1:47653"


def request(method: str, path: str, body=None, timeout: float = 90):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {} if body is None else {"Content-Type": "application/json"}
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def walk_texts(node, out):
    for text in node.get("texts") or []:
        out.append(text)
    for child in node.get("children") or []:
        walk_texts(child, out)


def find_button(tree, label):
    found = []

    def walk(node):
        texts = node.get("texts") or []
        if node.get("role") == "AXButton" and label in texts and node.get("id"):
            found.append(node)
        for child in node.get("children") or []:
            walk(child)

    walk(tree or {})
    return found[0] if found else None


def display_text(payload):
    found = []

    def walk(node):
        texts = node.get("texts") or []
        if "main display" in texts:
            for text in texts:
                if text in ("main display", "text") or text.startswith("_NS:"):
                    continue
                found.append(text)
        for child in node.get("children") or []:
            walk(child)

    walk((payload or {}).get("tree") or {})
    return found[0] if found else ""


def start_skill():
    subprocess.run([str(ROOT / "skill" / "start.sh")], check=True, cwd=ROOT)


def register_calculator():
    body = {
        "steps": [{
            "id": "attach-gui-reader",
            "action": "attachPlugin",
            "capability": "gui.read",
            "targetApp": "calculator",
        }],
        "listener": {
            "operation": "register",
            "listener": "bench",
            "subjects": ["gui.changed"],
        },
    }
    status, raw = request("POST", "/session", body, timeout=120)
    if status != 200:
        raise SystemExit("register failed: %s %s" % (status, raw[:200]))
    return json.loads(raw.decode("utf-8"))


def snapshot():
    status, raw = request("GET", "/snapshot", timeout=120)
    if status != 200:
        raise SystemExit("snapshot failed: %s %s" % (status, raw[:300]))
    return json.loads(raw.decode("utf-8"))


def perform_click(node_id: str):
    status, raw = request(
        "POST",
        "/perform",
        {"action": "click", "nodeId": node_id},
        timeout=120,
    )
    if status != 200:
        raise SystemExit("perform failed: %s %s" % (status, raw[:300]))


def ax_read_metrics(snap):
    texts = []
    walk_texts(snap.get("tree") or {}, texts)
    unique = []
    for item in texts:
        if item not in unique:
            unique.append(item)
    hit = [label for label in REQUIRED_LABELS if label in texts]
    miss = [label for label in REQUIRED_LABELS if label not in texts]
    return {
        "required": REQUIRED_LABELS,
        "hit": hit,
        "miss": miss,
        "label_recall": round(len(hit) / len(REQUIRED_LABELS), 4),
        "node_text_count": len(texts),
        "unique_text_count": len(unique),
        "has_stable_ids": True,
        "needs_vision_model": False,
    }


def find_clear_button(tree):
    # Calculator shows "all clear" at 0 and "clear" once a value is entered.
    for label in ("all clear", "clear"):
        button = find_button(tree, label)
        if button is not None:
            return button
    return None


def ensure_display_zero(snap):
    if display_text(snap) == "0":
        return snap
    clear = find_clear_button(snap.get("tree"))
    if clear is None:
        raise SystemExit("no clear button")
    perform_click(clear["id"])
    after = snapshot()
    if display_text(after) != "0":
        raise SystemExit("display after clear is %s" % display_text(after))
    return after


def ax_click_trials():
    """Click digits 1..5; after each click, read display back (expects concatenation)."""
    snap = ensure_display_zero(snapshot())
    trials = []
    expected = ""
    for label in ("1", "2", "3", "4", "5"):
        expected = expected + label
        button = find_button(snap.get("tree"), label)
        if button is None:
            trials.append({"label": label, "ok": False, "error": "button missing"})
            break
        t0 = time.perf_counter()
        perform_click(button["id"])
        click_ms = round((time.perf_counter() - t0) * 1000, 1)
        snap = snapshot()
        shown = display_text(snap)
        trials.append({
            "label": label,
            "ok": shown == expected,
            "expected": expected,
            "display": shown,
            "click_ms": click_ms,
            "nodeId": button["id"],
        })
        if shown != expected:
            break
    return trials


def ocr_metrics(png_path: Path):
    binary = ROOT / "bench" / "ocr-screenshot"
    swift = ROOT / "bench" / "ocr-screenshot.swift"
    argv = [str(binary), str(png_path)] if binary.is_file() and os.access(binary, os.X_OK) else ["swift", str(swift), str(png_path)]
    proc = subprocess.run(
        argv,
        capture_output=True,
        text=True,
        cwd=ROOT,
        timeout=180,
    )
    if proc.returncode != 0:
        return {
            "ok": False,
            "error": (proc.stderr or proc.stdout or "ocr failed")[-800:],
            "needs_vision_model": False,
            "engine": "macos-vision-ocr",
            "has_stable_ids": False,
        }
    payload = json.loads(proc.stdout)
    lines = payload.get("lines") or []
    joined = " ".join(lines)
    # Substring score (lenient; digits may match unrelated on-screen numerals).
    sub_hit = [label for label in REQUIRED_LABELS if label in joined]
    # Token score (stricter): label equals a line or a whitespace token.
    tok_hit = []
    for label in REQUIRED_LABELS:
        for line in lines:
            tokens = line.replace("•", " ").split()
            if line.strip() == label or label in tokens:
                tok_hit.append(label)
                break
    return {
        "ok": True,
        "engine": payload.get("engine"),
        "lines": lines,
        "hit": sub_hit,
        "miss": [label for label in REQUIRED_LABELS if label not in sub_hit],
        "label_recall": round(len(sub_hit) / len(REQUIRED_LABELS), 4),
        "token_hit": tok_hit,
        "token_miss": [label for label in REQUIRED_LABELS if label not in tok_hit],
        "token_label_recall": round(len(tok_hit) / len(REQUIRED_LABELS), 4),
        "has_stable_ids": False,
        "needs_vision_model": False,
        "note": (
            "Local Vision OCR on one full-screen shot — not a cloud VLM computer-use agent. "
            "token_label_recall is stricter than substring label_recall."
        ),
    }


def capture_calculator_png(dest: Path):
    subprocess.run(["open", "-a", "Calculator"], check=False)
    time.sleep(1.0)
    dest.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ["screencapture", "-x", str(dest)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not dest.is_file():
        raise SystemExit("screenshot failed: %s" % (proc.stderr or proc.stdout))
    return dest


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    start_skill()
    t_reg0 = time.perf_counter()
    register_calculator()
    register_ms = round((time.perf_counter() - t_reg0) * 1000, 1)

    t_read0 = time.perf_counter()
    snap = snapshot()
    read_ms = round((time.perf_counter() - t_read0) * 1000, 1)
    ax_read = ax_read_metrics(snap)
    ax_read["read_ms"] = read_ms
    ax_read["register_ms"] = register_ms

    clicks = ax_click_trials()
    ax_click_success = sum(1 for c in clicks if c.get("ok")) / len(clicks) if clicks else 0.0
    ax_click_ms = [c["click_ms"] for c in clicks if "click_ms" in c]

    png = OUT_DIR / "calculator-screen.png"
    t_shot0 = time.perf_counter()
    capture_calculator_png(png)
    shot_ms = round((time.perf_counter() - t_shot0) * 1000, 1)
    t_ocr0 = time.perf_counter()
    ocr = ocr_metrics(png)
    ocr_ms = round((time.perf_counter() - t_ocr0) * 1000, 1)
    ocr["screenshot_ms"] = shot_ms
    ocr["ocr_ms"] = ocr_ms

    report = {
        "host": {
            "machine": os.uname().machine,
            "sysname": os.uname().sysname,
            "release": os.uname().release,
        },
        "target": "Calculator",
        "measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "app_use": {
            "read": ax_read,
            "write": {
                "trials": clicks,
                "success_rate": round(ax_click_success, 4),
                "click_ms_median": sorted(ax_click_ms)[len(ax_click_ms) // 2] if ax_click_ms else None,
                "has_stable_ids": True,
                "needs_vision_model": False,
            },
        },
        "screenshot_ocr": ocr,
        "not_measured": {
            "cloud_vlm_computer_use": (
                "No cloud VLM was called on this host. Typical screenshot→VLM→pixel-click "
                "paths need a vision model, have no AX stable node ids, and incur API latency/cost. "
                "Do not treat this row as a numeric score."
            )
        },
    }

    out_json = OUT_DIR / "compare-calculator.json"
    out_json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({
        "wrote": str(out_json),
        "ax_label_recall": ax_read["label_recall"],
        "ax_click_success_rate": report["app_use"]["write"]["success_rate"],
        "ax_read_ms": read_ms,
        "ocr_label_recall": ocr.get("label_recall"),
        "ocr_ms": ocr_ms,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

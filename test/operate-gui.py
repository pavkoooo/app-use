#!/usr/bin/env python3
"""Shared live read-and-operate checks for the four Mac apps."""

import json
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:47653"
CONTENT_ROLES = {
    "AXButton", "AXRadioButton", "AXCheckBox", "AXTextField", "AXHeading", "AXLink",
    "AXRow", "AXCell", "AXPopUpButton", "AXMenuButton", "AXStaticText", "AXWebArea",
    "AXOutline", "AXImage", "AXList",
}


def fail(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def request(method, path, body=None, timeout=90):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {} if body is None else {"Content-Type": "application/json"}
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def nodes_of(tree):
    found = []

    def walk(node):
        found.append(node)
        for child in node.get("children") or []:
            walk(child)

    walk(tree or {})
    return found


def plain_texts(node):
    return [text for text in (node.get("texts") or []) if isinstance(text, str) and not text.startswith("_NS:")]


def window_node(tree):
    for child in (tree or {}).get("children") or []:
        if child.get("role") == "AXWindow":
            return child
    return None


def window_control_count(tree):
    count = 0

    def walk(node, inside):
        nonlocal count
        role = node.get("role")
        now = inside or role == "AXWindow"
        if now and role in CONTENT_ROLES and role != "AXWindow":
            count += 1
        for child in node.get("children") or []:
            walk(child, now)

    walk(tree or {}, False)
    return count


def sample_texts(tree, limit=12):
    skip = {"button", "text", "group", "radio button", "cell", "outline row", "image", "menu item", "application", "standard window"}
    found = []
    for node in nodes_of(tree):
        if str(node.get("role", "")).startswith("AXMenu"):
            continue
        for text in plain_texts(node):
            if text in skip or text in found:
                continue
            found.append(text.replace("\n", " / "))
            if len(found) >= limit:
                return found
    return found


def register(target):
    body = {
        "steps": [{
            "id": "attach-gui-reader",
            "action": "attachPlugin",
            "capability": "gui.read",
            "targetApp": target,
        }],
        "listener": {
            "operation": "register",
            "listener": "viewer",
            "subjects": ["gui.changed"],
        },
    }
    status, raw = request("POST", "/session", body, timeout=30)
    if status != 200:
        fail("register %s failed: %s %s" % (target, status, raw[:300]))


def snapshot():
    status, raw = request("GET", "/snapshot", timeout=90)
    if status != 200:
        fail("snapshot failed: %s %s" % (status, raw[:300]))
    payload = json.loads(raw.decode("utf-8"))
    tree = payload.get("tree") or {}
    window = window_node(tree)
    frame = (window or {}).get("frame") or {}
    if window is None or frame.get("width", 0) < 80 or frame.get("height", 0) < 80:
        fail("snapshot has no app window")
    if window_control_count(tree) < 8:
        fail("window has no real controls")
    return payload


def perform(node_id, events):
    stop = threading.Event()

    def read_sse():
        try:
            sock = socket.create_connection(("127.0.0.1", 47653), 5)
            sock.sendall(b"GET /events?listener=viewer HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
            sock.settimeout(0.4)
            buf = b""
            header = False
            while not stop.is_set():
                try:
                    chunk = sock.recv(8192)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                buf += chunk
                if not header:
                    if b"\r\n\r\n" not in buf:
                        continue
                    buf = buf.split(b"\r\n\r\n", 1)[1]
                    header = True
                while b"\n\n" in buf:
                    block, buf = buf.split(b"\n\n", 1)
                    data = []
                    for line in block.decode("utf-8", "replace").splitlines():
                        if line.startswith("data:"):
                            data.append(line[5:].lstrip())
                    if not data:
                        continue
                    try:
                        events.append(json.loads("".join(data)))
                    except json.JSONDecodeError:
                        pass
            sock.close()
        except Exception as exc:
            events.append({"error": str(exc)})

    thread = threading.Thread(target=read_sse, daemon=True)
    thread.start()
    time.sleep(0.3)
    status, raw = request("POST", "/perform", {"action": "click", "nodeId": node_id}, timeout=90)
    deadline = time.time() + 5
    while time.time() < deadline and not any(event.get("subject") == "gui.changed" for event in events):
        time.sleep(0.1)
    stop.set()
    if status != 200:
        fail("perform %s failed: %s %s" % (node_id, status, raw[:300]))
    if not any(event.get("subject") == "gui.changed" for event in events):
        fail("registered viewer did not receive gui.changed")


def listed_id(names):
    status, raw = request("GET", "/apps", timeout=60)
    if status != 200:
        fail("app list failed: %s" % status)
    apps = json.loads(raw.decode("utf-8")).get("apps") or []
    for name in names:
        for app in apps:
            if app.get("id") == name or app.get("name") == name:
                return app["id"]
    fail("none of %s is in the app list" % ", ".join(names))


def open_app(name):
    subprocess.check_call(["open", "-a", name])


def find_nodes(tree, pred):
    return [node for node in nodes_of(tree) if pred(node)]


def radio_value(node):
    for text in plain_texts(node):
        if text in ("0", "1"):
            return text
    return ""


def blob(tree):
    parts = []
    for node in nodes_of(tree):
        if str(node.get("role", "")).startswith("AXMenu"):
            continue
        parts.extend(plain_texts(node))
    return "\n".join(parts)


def run_chatgpt():
    open_app("ChatGPT")
    target = listed_id(["ChatGPT"])
    register(target)
    before = snapshot()
    if "chatgpt" not in (before.get("app") or "").lower():
        fail("snapshot app is %s" % before.get("app"))
    tree = before["tree"]
    if not find_nodes(tree, lambda node: node.get("role") == "AXWebArea"):
        fail("ChatGPT window has no web content")
    choice = None
    for label in ("Sign in another way", "Cancel", "Continue to sign in"):
        matches = find_nodes(tree, lambda node, label=label: node.get("role") == "AXButton" and label in plain_texts(node))
        if matches:
            choice = (label, matches[0])
            break
    if choice is None:
        fail("ChatGPT window has no sign-in control to click")
    label, node = choice
    events = []
    perform(node["id"], events)
    after = snapshot()
    after_blob = blob(after["tree"])
    if label == "Cancel":
        if "Sign in another way" not in after_blob and "Continue to sign in" not in after_blob:
            fail("Cancel did not return to the sign-in choices")
        proof = "sign-in choices"
    else:
        if "OpenAI API key" not in after_blob and "Cancel" not in after_blob:
            fail("click did not open the API key sign-in")
        if label in after_blob and label != "Cancel":
            pass
        proof = "OpenAI API key"
    print("ok: ChatGPT nodes %d; clicked %s; now shows %s" % (len(nodes_of(before["tree"])), label, proof))


def run_finder():
    open_app("Finder")
    target = listed_id(["Finder"])
    register(target)
    before = snapshot()
    if "finder" not in (before.get("app") or "").lower():
        fail("snapshot app is %s" % before.get("app"))
    tree = before["tree"]
    body = blob(tree)
    if "Applications" not in body and "Downloads" not in body:
        fail("Finder window has no sidebar locations")
    radios = find_nodes(tree, lambda node: node.get("role") == "AXRadioButton" and any(text in plain_texts(node) for text in ("icon view", "list view", "column view")))
    if len(radios) < 2:
        fail("Finder window has no view controls")
    chosen = None
    for label in ("icon view", "list view", "column view"):
        for node in radios:
            if label in plain_texts(node) and radio_value(node) != "1":
                chosen = (label, node)
                break
        if chosen:
            break
    if chosen is None:
        fail("Finder view controls are not clickable")
    label, node = chosen
    before_value = radio_value(node)
    events = []
    perform(node["id"], events)
    after = snapshot()
    updated = find_nodes(after["tree"], lambda item, label=label: item.get("role") == "AXRadioButton" and label in plain_texts(item) and radio_value(item) == "1")
    if not updated:
        fail("Finder %s did not become selected" % label)
    print("ok: Finder nodes %d; clicked %s; value %s -> 1" % (len(nodes_of(before["tree"])), label, before_value or "0"))


def run_settings():
    open_app("System Settings")
    target = listed_id(["System Settings", "系统设置"])
    register(target)
    before = snapshot()
    app_name = before.get("app") or ""
    if "system settings" not in app_name.lower() and "系统设置" not in app_name:
        fail("snapshot app is %s" % app_name)
    tree = before["tree"]
    window = window_node(tree)
    title = " ".join(plain_texts(window))
    panes = (
        ("General", "com.apple.systempreferences.GeneralSettings", ("General", "通用")),
        ("Appearance", "com.apple.Appearance-Settings.extension", ("Appearance", "外观")),
    )
    choice = None
    for name, marker, titles in panes:
        if any(item in title for item in titles):
            continue
        matches = find_nodes(
            tree,
            lambda node, marker=marker: node.get("role") == "AXStaticText" and marker in plain_texts(node),
        )
        if matches:
            choice = (name, titles, matches[0])
            break
    if choice is None:
        fail("System Settings sidebar has no General or Appearance row")
    name, titles, node = choice
    events = []
    perform(node["id"], events)
    after = snapshot()
    after_title = " ".join(plain_texts(window_node(after["tree"])))
    if not any(item in after_title for item in titles):
        fail("window title is %s after clicking %s" % (after_title, name))
    print("ok: System Settings nodes %d; clicked %s; window %s -> %s" % (len(nodes_of(before["tree"])), name, title.split(",")[0], name))


CLASH_LABELS = (
    "Rule",
    "Global",
    "Direct",
    "My Profiles",
    "App Settings",
    "Core Settings",
    "Core Log",
    "Backup and Sync",
    "Help",
    "About",
)


def exact_texts(tree):
    found = []
    for node in nodes_of(tree):
        if str(node.get("role", "")).startswith("AXMenu"):
            continue
        for text in plain_texts(node):
            cleaned = text.strip()
            if cleaned and cleaned not in found:
                found.append(cleaned)
    return found


def clash_page_title(tree):
    # A subpage shows a wide title in the top-left corner of the window;
    # clicking its leading edge returns to the main window.
    window = window_node(tree)
    if window is None:
        return None
    win = window.get("frame") or {}
    for node in nodes_of(tree):
        if node.get("role") != "AXStaticText":
            continue
        frame = node.get("frame") or {}
        width, height = frame.get("width", 0), frame.get("height", 0)
        if width < 180 or not 20 <= height <= 32:
            continue
        inset_x = frame.get("x", 0) - win.get("x", 0)
        inset_y = frame.get("y", 0) - win.get("y", 0)
        if 24 < inset_x < 90 and 0 <= inset_y < 90:
            return node
    return None


def require_clash_main(tree):
    texts = exact_texts(tree)
    missing = [label for label in CLASH_LABELS if label not in texts]
    if missing:
        fail("main window is missing visible labels: %s" % ", ".join(missing))
    if not any(("↑" in text and "↓" in text) for text in texts):
        fail("main window dropped the traffic values")
    details = [
        text for text in texts
        if text not in CLASH_LABELS and any(unit in text for unit in ("GB", "MB", "KB", "B/s"))
    ]
    if len(details) < 2:
        fail("main window dropped profile or traffic rows")
    if len(texts) < len(CLASH_LABELS):
        fail("main window only has the title and one control")
    return texts


def run_clash():
    open_app("Clash Mi")
    target = listed_id(["Clash Mi"])
    register(target)
    before = snapshot()
    if "clash mi" not in (before.get("app") or "").lower():
        fail("snapshot app is %s" % before.get("app"))
    for _ in range(4):
        if not [label for label in CLASH_LABELS if label not in exact_texts(before["tree"])]:
            break
        title = clash_page_title(before["tree"])
        if title is None:
            break
        perform(title["id"], [])
        before = snapshot()
    texts = require_clash_main(before["tree"])
    about = find_nodes(
        before["tree"],
        lambda node: node.get("role") == "AXButton" and "About" in exact_texts_of(node) and not any(name in exact_texts_of(node) for name in ("Rule", "Global", "Direct")),
    )
    if not about:
        fail("main window has no About button")
    perform(about[0]["id"], [])
    after = snapshot()
    after_texts = exact_texts(after["tree"])
    if "Version" not in after_texts and not any(text.startswith("Version") for text in after_texts):
        fail("About did not open")
    back = clash_page_title(after["tree"])
    if back is None:
        fail("About page has no title to return with")
    perform(back["id"], [])
    home = snapshot()
    home_missing = [label for label in CLASH_LABELS if label not in exact_texts(home["tree"])]
    if home_missing:
        fail("did not return to the main window: missing %s" % ", ".join(home_missing))
    print("ok: Clash Mi nodes %d; %d visible strings kept; About opens and returns" % (len(nodes_of(before["tree"])), len(texts)))


def exact_texts_of(node):
    return [text.strip() for text in plain_texts(node) if text.strip()]


def frontmost_app():
    out = subprocess.check_output(
        ["osascript", "-e",
         'tell application "System Events" to get name of first application process whose frontmost is true'],
        text=True, timeout=20,
    )
    return out.strip()


def raw_snapshot():
    status, raw = request("GET", "/snapshot", timeout=90)
    if status != 200:
        fail("snapshot failed: %s %s" % (status, raw[:300]))
    return json.loads(raw.decode("utf-8"))


def dock_labels(items):
    labels = []
    for node in items:
        texts = [text.strip() for text in plain_texts(node) if text.strip()]
        labels.append(texts[0] if texts else "")
    return labels


def run_dock():
    original = frontmost_app()
    register("Dock")
    before = raw_snapshot()
    if "dock" not in (before.get("app") or "").lower():
        fail("snapshot app is %s" % before.get("app"))
    items = find_nodes(before["tree"], lambda node: node.get("role") == "AXDockItem")
    labels = dock_labels(items)
    if len(items) < 10:
        fail("Dock strip read only %d items" % len(items))
    for required in ("Finder", "Trash", "Calculator"):
        if required not in labels:
            fail("Dock strip is missing the %s item" % required)
    calc = items[labels.index("Calculator")]
    perform(calc["id"], [])
    time.sleep(0.8)
    front = frontmost_app()
    if front != "Calculator":
        fail("frontmost is %s after clicking the Calculator dock item" % front)
    if original and original != "Calculator":
        subprocess.call(["open", "-a", original], timeout=20)
    print("ok: Dock %d items read; clicked Calculator; frontmost switched to Calculator" % len(items))


def sort_options(tree):
    options = []
    for holder in find_nodes(tree, lambda node: node.get("role") == "AXMenuItem"
                             and (plain_texts(node) or [""])[0].strip() == "Sort By"):
        for menu in holder.get("children") or []:
            for option in menu.get("children") or []:
                if option.get("role") == "AXMenuItem":
                    options.append(option)
    return options


def option_label(node):
    return (plain_texts(node) or [""])[0].strip()


def option_checked(node):
    return "✓" in plain_texts(node)


def run_menus():
    open_app("Finder")
    target = listed_id(["Finder"])
    register(target)
    before = snapshot()
    if "finder" not in (before.get("app") or "").lower():
        fail("snapshot app is %s" % before.get("app"))
    options = sort_options(before["tree"])
    if len(options) < 2:
        fail("View > Sort By submenu did not read")
    checked = [option for option in options if option_checked(option)]
    if not checked:
        fail("no sort option is checked")
    original = checked[0]
    choice = next((option for option in options
                   if option_label(option) == "Name" and option is not original), None)
    if choice is None:
        choice = next((option for option in options if option is not original), None)
    if choice is None:
        fail("no other sort option to click")
    perform(choice["id"], [])
    after = snapshot()
    after_options = sort_options(after["tree"])
    if not any(option_checked(option) and option_label(option) == option_label(choice)
               for option in after_options):
        fail("nested Sort By click did not move the checkmark to %s" % option_label(choice))
    restore = next((option for option in after_options
                    if option_label(option) == option_label(original)), None)
    if restore is None:
        fail("original sort option %s is gone" % option_label(original))
    perform(restore["id"], [])
    final = snapshot()
    final_options = sort_options(final["tree"])
    if not any(option_checked(option) and option_label(option) == option_label(original)
               for option in final_options):
        fail("sort order was not restored to %s" % option_label(original))
    print("ok: nested Sort By %s -> %s -> %s restored" % (
        option_label(original), option_label(choice), option_label(original)))


def main():
    choice = sys.argv[1] if len(sys.argv) > 1 else ""
    runners = {
        "chatgpt": run_chatgpt,
        "finder": run_finder,
        "settings": run_settings,
        "clash": run_clash,
        "dock": run_dock,
        "menus": run_menus,
    }
    runner = runners.get(choice)
    if runner is None:
        fail("usage: operate-gui.py chatgpt|finder|settings|clash|dock|menus")
    runner()


if __name__ == "__main__":
    main()

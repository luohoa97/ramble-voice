#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""End-to-end test driver for the Ramble Voice Android keyboard.

Runs as an MCP server over stdio (no dependencies), or as a CLI:

    tool/e2e/ramble_e2e_mcp.py                 # MCP server (stdio)
    tool/e2e/ramble_e2e_mcp.py cli state       # one command, prints JSON
    tool/e2e/ramble_e2e_mcp.py cli wav clip.wav
    tool/e2e/ramble_e2e_mcp.py cli screenshot out.png

Everything goes through adb. Keyboard commands reach the app's E2eReceiver,
which only the adb shell may call (android.permission.DUMP). Set
RAMBLE_ADB_SERIAL to pick a device when several are attached.
"""

import base64
import shlex
import json
import os
import re
import subprocess
import sys
import time

PKG = "io.github.luohoa97.ramblevoice"
FILES = f"/sdcard/Android/data/{PKG}/files"
REPLY = f"{FILES}/e2e/reply.json"


def _adb_path():
    """The SDK's adb (a distro adb of another version would restart the server)."""
    for c in (os.environ.get("ADB"), os.path.expanduser("~/Android/Sdk/platform-tools/adb")):
        if c and os.path.exists(c):
            return c
    return "adb"


def adb(*args, binary=False, timeout=60, check=True):
    cmd = [_adb_path()]
    serial = os.environ.get("RAMBLE_ADB_SERIAL")
    if serial:
        cmd += ["-s", serial]
    cmd += list(args)
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(p.stderr.decode(errors="replace").strip() or f"adb {args[0]} failed")
    return p.stdout if binary else p.stdout.decode(errors="replace")


def keyboard(cmd, arg=None, wait=10.0):
    """Sends a command to the keyboard and returns its JSON reply."""
    adb("shell", "rm", "-f", REPLY, check=False)
    extra = ["--es", "arg", arg] if arg is not None else []
    # adb shell runs a remote shell: quote every word (text may hold spaces, newlines).
    words = ["am", "broadcast", "-a", f"{PKG}.E2E", "-n", f"{PKG}/.E2eReceiver", "--es", "cmd", cmd, *extra]
    adb("shell", " ".join(shlex.quote(w) for w in words))
    until = time.time() + wait
    while time.time() < until:
        out = adb("shell", "cat", REPLY, check=False).strip()
        if out.startswith("{"):
            return json.loads(out)
        time.sleep(0.25)
    return {"ok": False, "cmd": cmd, "error": "no reply (is the Ramble keyboard showing?)"}


def wait_done(timeout=60.0):
    """Polls until the dictation leaves listening/processing."""
    until = time.time() + timeout
    s = {}
    while time.time() < until:
        s = keyboard("state")
        if s.get("state") not in ("DictationStarting", "DictationListening", "DictationProcessing") and \
                s.get("edit") not in ("resolving", "listening", "processing"):
            return s
        time.sleep(0.7)
    s["timeout"] = True
    return s


def play_wav(path, edit=False, wait=True):
    remote = f"{FILES}/e2e/in.wav"
    adb("shell", "mkdir", "-p", f"{FILES}/e2e")
    adb("push", path, remote)
    # The app reads its own external files path (same storage, app view).
    r = keyboard("wav", ("edit:" if edit else "") + f"/storage/emulated/0/Android/data/{PKG}/files/e2e/in.wav")
    if not r.get("ok") or not wait:
        return r
    time.sleep(r.get("seconds", 0) + 0.5)
    return wait_done()


def screenshot():
    return adb("exec-out", "screencap", "-p", binary=True)


def ui_fields():
    """Editable fields on screen (uiautomator), with focus and text."""
    adb("shell", "uiautomator", "dump", "/sdcard/ramble_ui.xml", check=False, timeout=30)
    xml = adb("shell", "cat", "/sdcard/ramble_ui.xml", check=False)
    adb("shell", "rm", "-f", "/sdcard/ramble_ui.xml", check=False)
    fields = []
    for node in re.finditer(r"<node [^>]*>", xml):
        n = node.group(0)
        attr = dict(re.findall(r'(\w[\w-]*)="([^"]*)"', n))
        if attr.get("class", "").endswith("EditText") or attr.get("focused") == "true" and attr.get("text"):
            fields.append({k: attr.get(k) for k in ("class", "package", "text", "focused", "bounds", "resource-id")})
    return fields


def logs(which="dart", lines=60):
    name = {"dart": "dart.log", "native": "native.log"}.get(which, "dart.log")
    out = adb("shell", "tail", "-n", str(int(lines)), f"{FILES}/logs/{name}", check=False)
    return out


TOOLS = {
    "keyboard": {
        "description": "Press a Ramble keyboard control or read its state. cmd: state, toggle, start, stop, pause, "
                       "resume, discard, edit, editStop, editUndo, abc, enter, backspace, insert (arg = text, uses "
                       "the real dictation insert path). The keyboard must be showing.",
        "schema": {"type": "object", "properties": {"cmd": {"type": "string"}, "arg": {"type": "string"}},
                   "required": ["cmd"]},
        "run": lambda a: keyboard(a["cmd"], a.get("arg")),
    },
    "wait_done": {
        "description": "Wait until the current dictation or edit finishes, then return the keyboard state "
                       "(lastText = cleaned text, field.before/after = field contents around the cursor).",
        "schema": {"type": "object", "properties": {"timeout": {"type": "number"}}},
        "run": lambda a: wait_done(a.get("timeout", 60)),
    },
    "play_wav": {
        "description": "Replay a local 16 kHz mono 16-bit WAV through the keyboard as if spoken (dictation, or an "
                       "edit instruction when edit=true), wait for the result, return the state.",
        "schema": {"type": "object", "properties": {"path": {"type": "string"}, "edit": {"type": "boolean"}},
                   "required": ["path"]},
        "run": lambda a: play_wav(a["path"], a.get("edit", False)),
    },
    "screenshot": {
        "description": "Screenshot of the phone.",
        "schema": {"type": "object", "properties": {}},
        "run": None,
    },
    "fields": {
        "description": "Editable text fields on screen (uiautomator dump): text, focus, bounds.",
        "schema": {"type": "object", "properties": {}},
        "run": lambda a: ui_fields(),
    },
    "tap": {
        "description": "Tap the screen at pixel x,y.",
        "schema": {"type": "object", "properties": {"x": {"type": "integer"}, "y": {"type": "integer"}},
                   "required": ["x", "y"]},
        "run": lambda a: adb("shell", "input", "tap", str(a["x"]), str(a["y"])) or "ok",
    },
    "launch": {
        "description": "Open an app by package name.",
        "schema": {"type": "object", "properties": {"package": {"type": "string"}}, "required": ["package"]},
        "run": lambda a: adb("shell", "monkey", "-p", a["package"], "-c", "android.intent.category.LAUNCHER", "1"),
    },
    "logs": {
        "description": "Tail the app's dart or native log.",
        "schema": {"type": "object", "properties": {"which": {"type": "string", "enum": ["dart", "native"]},
                                                    "lines": {"type": "integer"}}},
        "run": lambda a: logs(a.get("which", "dart"), a.get("lines", 60)),
    },
}


def call_tool(name, args):
    if name == "screenshot":
        return [{"type": "image", "data": base64.b64encode(screenshot()).decode(), "mimeType": "image/png"}]
    out = TOOLS[name]["run"](args or {})
    text = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False, indent=1)
    return [{"type": "text", "text": text}]


def serve():
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        mid = msg.get("id")
        method = msg.get("method")
        if mid is None:
            continue  # notification
        try:
            if method == "initialize":
                result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                          "capabilities": {"tools": {}},
                          "serverInfo": {"name": "ramble-e2e", "version": "1.0"}}
            elif method == "tools/list":
                result = {"tools": [{"name": k, "description": v["description"], "inputSchema": v["schema"]}
                                    for k, v in TOOLS.items()]}
            elif method == "tools/call":
                p = msg["params"]
                try:
                    result = {"content": call_tool(p["name"], p.get("arguments"))}
                except Exception as e:  # reported to the caller, not fatal
                    result = {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True}
            elif method == "ping":
                result = {}
            else:
                raise KeyError(method)
            reply = {"jsonrpc": "2.0", "id": mid, "result": result}
        except KeyError as e:
            reply = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"unknown method {e}"}}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


def cli(argv):
    name, rest = argv[0], argv[1:]
    if name == "screenshot":
        out = rest[0] if rest else "screen.png"
        open(out, "wb").write(screenshot())
        print(out)
    elif name == "wav":
        print(json.dumps(play_wav(rest[0], edit="--edit" in rest), ensure_ascii=False, indent=1))
    elif name in ("fields", "wait_done"):
        print(json.dumps(TOOLS[name]["run"]({}), ensure_ascii=False, indent=1))
    elif name == "logs":
        print(logs(*(rest[:1] or ["dart"]), *(rest[1:2] or [60])))
    else:
        print(json.dumps(keyboard(name, rest[0] if rest else None), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "cli":
        cli(sys.argv[2:])
    else:
        serve()

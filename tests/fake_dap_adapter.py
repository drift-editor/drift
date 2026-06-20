#!/usr/bin/env python3
"""Minimal fake DAP adapter for lifecycle testing.

Reads DAP messages from stdin, sends responses and the required
`initialized` event after the `initialize` request.
"""
import json
import sys


def send(msg: dict) -> None:
    data = json.dumps(msg)
    header = f"Content-Length: {len(data)}\r\n\r\n"
    sys.stdout.write(header + data)
    sys.stdout.flush()


def recv():
    header = b""
    while True:
        ch = sys.stdin.buffer.read(1)
        if not ch:
            return None
        header += ch
        if header.endswith(b"\r\n\r\n"):
            break
    content_length = 0
    for line in header.decode("ascii").split("\r\n"):
        if line.startswith("Content-Length:"):
            content_length = int(line.split(":", 1)[1].strip())
            break
    data = sys.stdin.buffer.read(content_length).decode("utf-8")
    return json.loads(data)


def main():
    # Ignore any command-line args (e.g. --stdio)
    while True:
        msg = recv()
        if msg is None:
            break
        if msg.get("type") != "request":
            continue
        seq = msg.get("seq", 0)
        cmd = msg.get("command", "")
        send({
            "type": "response",
            "request_seq": seq,
            "success": True,
            "command": cmd,
        })
        if cmd == "initialize":
            send({"type": "event", "event": "initialized", "seq": 0})


if __name__ == "__main__":
    main()

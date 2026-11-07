"""Automated children never open console windows; GUI windows stay available.

For an entire Zig build use run_console_tree: its pinned builder spawns children
without CREATE_NO_WINDOW, so those children need one shared, hidden console.
Launchers accept the command as their only positional argument.
"""
from __future__ import annotations

import argparse
import copy
import os
from pathlib import Path
import subprocess
import traceback


def _options(options, *, console_tree=False, stdio_forced=False):
    result = dict(options)
    if os.name != "nt":
        return result
    flags = result.get("creationflags", 0)
    if flags & (subprocess.CREATE_NEW_CONSOLE | subprocess.DETACHED_PROCESS):
        raise ValueError("automated console ownership is selected by automation_process")
    if console_tree:
        # Hide only this new console, never the user's existing terminal.
        startup = copy.copy(result.get("startupinfo")) if result.get("startupinfo") else subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        result["startupinfo"] = startup
        result["creationflags"] = (flags & ~subprocess.CREATE_NO_WINDOW) | subprocess.CREATE_NEW_CONSOLE
    else:
        # CREATE_NO_WINDOW affects console allocation, not real GUI windows.
        result["creationflags"] = flags | subprocess.CREATE_NO_WINDOW
    if (not stdio_forced and not result.get("capture_output") and result.get("input") is None
            and all(result.get(stream) is None for stream in ("stdin", "stdout", "stderr"))):
        # With all streams implicit, Python omits STARTF_USESTDHANDLES. A child
        # without a console can then lose its parent's redirected output.
        # Explicit descriptors preserve nested build/verification logs as well.
        for stream, descriptor in (("stdin", 0), ("stdout", 1), ("stderr", 2)):
            try:
                os.fstat(descriptor)
            except OSError:
                result[stream] = subprocess.DEVNULL
            else:
                result[stream] = descriptor
    return result


def run(args, **kwargs):
    return subprocess.run(args, **_options(kwargs))


def Popen(args, **kwargs):
    return subprocess.Popen(args, **_options(kwargs))


def call(args, **kwargs):
    return subprocess.call(args, **_options(kwargs))


def check_output(args, **kwargs):
    return subprocess.check_output(args, **_options(kwargs, stdio_forced=True))


def run_console_tree(args, **kwargs):
    return subprocess.run(args, **_options(kwargs, console_tree=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console-tree", action="store_true", help="Shared hidden console for Zig builds")
    parser.add_argument("--log", type=Path, required=True, help="New log file; existing evidence is not overwritten")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("x", encoding="utf-8") as log:
        try:
            runner = run_console_tree if args.console_tree else run
            result = runner(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            print(f"\n[automation] exit={result.returncode}", file=log)
            return result.returncode
        except Exception:
            traceback.print_exc(file=log)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())

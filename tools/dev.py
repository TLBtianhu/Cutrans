"""Hidden developer commands with claimed logs; GUI targets remain explicit."""
from __future__ import annotations
import argparse
import base64
import json
from pathlib import Path
import re
import sys
import time
import traceback

sys.dont_write_bytecode = True
import automation_process as process
from verification_paths import BASE, claim, retain

ROOT = Path(__file__).resolve().parents[1]


def command_for(request: dict) -> tuple[list[str], bool]:
    if set(request) != {"action", "arguments"} or not isinstance(request["arguments"], list):
        raise ValueError("invalid developer request")
    arguments = request["arguments"]
    if not all(isinstance(value, str) and "\x00" not in value for value in arguments):
        raise ValueError("arguments must be NUL-free strings")
    python = str(Path(sys.executable).with_name("python.exe")) if sys.platform == "win32" else sys.executable
    if request["action"] == "bootstrap":
        return [python, "-B", "tools/bootstrap.py", *arguments], False
    if request["action"] == "verify-repository":
        return [python, "-B", "tools/repository_audit.py", *arguments], False
    if request["action"] == "build":
        zig = ROOT / "tools/zig/zig.exe"
        if not zig.is_file():
            raise RuntimeError("fixed Zig toolchain missing; run tools/dev.ps1 bootstrap first")
        return [str(zig), "build", *arguments], True
    raise ValueError("supported actions: bootstrap, build, verify-repository")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True)
    parser.add_argument("--request", required=True, help="UTF-8 JSON encoded as base64 by dev.ps1")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{12}", args.case):
        parser.error("invalid case identifier")
    evidence = claim(BASE / f"developer-{args.case}")
    retain(evidence)
    status = {"format": "cutrans-developer-command/1", "passed": False}
    started = time.monotonic()
    code = 1
    with (evidence / "run.log").open("x", encoding="utf-8") as log:
        try:
            request = json.loads(base64.b64decode(args.request, validate=True).decode("utf-8"))
            status["action"] = request.get("action")
            command, console_tree = command_for(request)
            runner = process.run_console_tree if console_tree else process.run
            result = runner(command, cwd=ROOT, stdin=process.subprocess.DEVNULL,
                            stdout=log, stderr=process.subprocess.STDOUT)
            code = result.returncode
            status.update(exit=code, passed=code == 0)
        except Exception as error:
            status["error"] = type(error).__name__
            traceback.print_exc(file=log)
        finally:
            status["seconds"] = time.monotonic() - started
            print(f"\n[automation] exit={code}", file=log)
            (evidence / "result.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    return code


if __name__ == "__main__":
    raise SystemExit(main())

"""Verify deterministic VM replay in isolated user environments."""

from __future__ import annotations

import hashlib
import shutil
from pathlib import Path

import automation_process

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, remove
from verification_context import command_args, mark_data
URI = "pack://assets/examples/replay.cvr"


def run(bootstrap: Path, mode: str, replay: str, data: Path, expected: int = 0) -> str:
    result = automation_process.run(command_args([str(bootstrap), f"--mode={mode}", f"--data={data}", f"--replay={replay}"]), capture_output=True, text=True)
    output = result.stdout + result.stderr
    print(output, end="")
    if result.returncode != expected:
        raise RuntimeError(f"unexpected replay exit code {result.returncode}, expected {expected}")
    return output


def summary(output: str) -> dict[str, str]:
    line = next((line for line in output.splitlines() if line.startswith("CUTRANS_REPLAY_OK")), "")
    if not line:
        raise RuntimeError("replay did not report success")
    return dict(token.split("=", 1) for token in line.split()[1:])


def main() -> None:
    bootstrap = (OUTPUT / "portable/cutrans_bootstrap.exe").resolve()
    root = default_root("replay-user")
    if root.exists():
        raise RuntimeError(f"replay verification root must be new: {root}")
    claim(root)
    first_data = root / "first"
    second_data = root / "second"
    first = summary(run(bootstrap, "portable", URI, first_data))
    second = summary(run(bootstrap, "portable", URI, second_data))
    if first != second:
        raise RuntimeError(f"isolated replay states diverged: {first} != {second}")
    first_document = (first_data / "documents/replay.cut").read_bytes()
    second_document = (second_data / "documents/replay.cut").read_bytes()
    if first_document != second_document or not first_document.startswith(b"version=3\n"):
        raise RuntimeError("replayed documents differ or were not migrated to v2")
    first_png = hashlib.sha256((first_data / "exports/replay.png").read_bytes()).hexdigest()
    second_png = hashlib.sha256((second_data / "exports/replay.png").read_bytes()).hexdigest()
    if first_png != second_png:
        raise RuntimeError("replayed PNG exports diverged")
    print(f"CUTRANS_REPLAY_STATE_OK fingerprint={first['fingerprint']} tasks={first['tasks']} history={first['history']} time_ns={first['time_ns']} png={first_png}")
    input_report = summary(run(bootstrap, "portable", "pack://assets/examples/input.cvr", root / "input"))
    if input_report.get("kind") != "1" or input_report.get("input_events") != "5" or input_report.get("time_ns") != "5000000":
        raise RuntimeError(f"semantic input replay returned an unexpected report: {input_report}")
    print("CUTRANS_INPUT_REPLAY_OK kind=1 events=5 time_ns=5000000")

    bad_data = root / "bad"
    mark_data(bad_data, "portable", OUTPUT / "portable/runtime")
    bad_log = bad_data / "bad.cvr"
    source = (ROOT / "assets/examples/replay.cvr").read_text(encoding="utf-8")
    bad_log.write_text(source.replace("ok,editor.gain.set", "invalid_arguments,editor.gain.set"), encoding="utf-8")
    output = run(bootstrap, "portable", "session://bad.cvr", bad_data, expected=1)
    if "ReplayResultMismatch" not in output:
        raise RuntimeError("unexpected replay result was not rejected")
    bad_log.write_text(source.replace("2000000", "1"), encoding="utf-8")
    output = run(bootstrap, "portable", "session://bad.cvr", bad_data, expected=1)
    if "ReplayTimeTravel" not in output:
        raise RuntimeError("time travel was not rejected")
    print("CUTRANS_REPLAY_NEGATIVE_OK mismatch=1 time_travel=1")
    bad_input = bad_data / "bad-input.cvr"
    input_source = (ROOT / "assets/examples/input.cvr").read_text(encoding="utf-8")
    bad_input.write_text(input_source.replace("2000000", "1"), encoding="utf-8")
    output = run(bootstrap, "portable", "session://bad-input.cvr", bad_data, expected=1)
    if "InputTimeTravel" not in output:
        raise RuntimeError("semantic input time travel was not rejected")
    print("CUTRANS_INPUT_NEGATIVE_OK time_travel=1")
    if (OUTPUT / "portable/data").exists():
        raise RuntimeError("replay polluted portable staging")
    retain(root)
    print("CUTRANS_REPLAY_VERIFY_OK instances=2 state=identical png=identical")


if __name__ == "__main__":
    main()

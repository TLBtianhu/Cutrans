"""Start the desktop through the VM and verify logs without visual or input automation."""

from __future__ import annotations

import re
import shutil
import subprocess
import threading
import time
from pathlib import Path

import automation_process

ROOT = Path(__file__).resolve().parents[1]
from build_paths import OUTPUT
from verification_paths import default_root, claim, retain, ensure_owned_data, check_root
from verification_context import command_args


SHELL_FRAME = re.compile(r"^CUTRANS_SHELL_FRAME_OK generation=([1-9][0-9]*) content=([0-9]+) t=(-?[0-9]+)$", re.MULTILINE)


def submitted_times(text: str) -> set[int]:
    # These records follow backend submission and a successful FrameReport RPC.
    # A playback mirror/cursor record or an independent Host log is insufficient.
    return {int(match.group(3)) for match in SHELL_FRAME.finditer(text)}


def start_and_verify(bootstrap: Path, document: Path, data: Path, mode: str, cleanup: bool = True, playback_frames: int | None = None, assets_demo: bool = False, settle_seconds: float = 0.0, cwd: Path | None = None) -> None:
    gui_cwd = ensure_owned_data(cwd if cwd is not None else data.parent / f"{data.name} gui-cwd")
    ini = check_root(gui_cwd / "imgui.ini")
    ini_before = (ini.read_bytes(), ini.stat().st_mtime_ns) if ini.exists() else None
    host_console = bootstrap if bootstrap.name == "cutrans_vm.exe" else None
    if host_console is not None:
        started = automation_process.run(command_args([str(host_console), "start", f"--mode={mode}", f"--data={data}"]), cwd=gui_cwd, capture_output=True, text=True)
        if started.returncode:
            raise RuntimeError("could not start the Host used by the desktop probe: " + started.stdout + started.stderr)
        bootstrap = host_console.parent / "cutrans_shell.exe"
    command = [str(bootstrap), f"--mode={mode}", f"--data={data}", "--open", str(document)]
    if playback_frames is not None:
        command.append(f"--playback={playback_frames}")
    if assets_demo:
        command.append("--assets-demo")
    process = automation_process.Popen(command_args(command), cwd=gui_cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    lines: list[str] = []

    def read_output() -> None:
        assert process.stdout is not None
        for line in process.stdout:
            lines.append(line)
            print(line, end="")

    thread = threading.Thread(target=read_output, daemon=True)
    thread.start()
    ready = False
    editor = False
    frame = False
    playback_ready = playback_frames is None
    assets_ready = not assets_demo
    ready_at: float | None = None
    settled = False
    try:
        deadline = time.time() + 90
        while time.time() < deadline and process.poll() is None:
            text = "".join(lines)
            frame_times = submitted_times(text)
            ready = ready or "Cutrans VM 桌面就绪" in text
            editor = editor or "app.open editor" in text
            frame = frame or bool(frame_times)
            assets_ready = assets_ready or "CUTRANS_SHELL_ASSETS_OK selected=1 preview=91x69 inserted=1 source_uri=1 snapshot=1 library=1" in text
            if playback_frames is not None:
                playback_ready = playback_ready or playback_frames - 1 in frame_times
            if ready and editor and frame and playback_ready and assets_ready:
                if ready_at is None:
                    ready_at = time.time()
                if time.time() - ready_at >= settle_seconds:
                    settled = True
                    break
            time.sleep(0.1)
        if not (ready and editor and frame and playback_ready and assets_ready and settled):
            raise RuntimeError("desktop shell or projected frame submission did not become ready: " + "".join(lines))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        thread.join(timeout=2)
        if process.stdout is not None:
            process.stdout.close()
        if host_console is not None:
            stopped = automation_process.run(command_args([str(host_console), "stop", f"--mode={mode}", f"--data={data}"]), cwd=gui_cwd, capture_output=True, text=True)
            if stopped.returncode:
                raise RuntimeError("could not stop the Host used by the desktop probe: " + stopped.stdout + stopped.stderr)
        if cleanup:
            retain(data)
        ini_after = (ini.read_bytes(), ini.stat().st_mtime_ns) if ini.exists() else None
        if ini_after != ini_before:
            raise RuntimeError(f"GUI created or modified cwd/imgui.ini; evidence retained: {ini}")
    print(f"CUTRANS_SHELL_CWD_OK ini={'absent' if ini_before is None else 'unchanged'}")
    if assets_demo:
        print("CUTRANS_SHELL_ASSETS_VERIFY_OK selected=1 preview=1 inserted=1 visual_acceptance=not_run")
    elif playback_frames is None:
        print("CUTRANS_SHELL_START_OK dynamic_vm=1 editor_open=1 frame_submit=log visual_acceptance=not_run")
    else:
        print(f"CUTRANS_SHELL_PLAYBACK_OK t={playback_frames - 1} frame_submit=log visual_acceptance=not_run")


def main() -> None:
    root = default_root("shell-user")
    retain(root)
    claim(root)
    document = root / "shell document.cut"
    shutil.copyfile(ROOT / "assets/examples/minimal.cut", document)
    missing = root / "missing-shell"
    missing.mkdir()
    missing_data = root / "missing-data"
    bootstrap = (OUTPUT / "portable/cutrans_vm.exe").resolve()
    shell = bootstrap.parent / "cutrans_shell.exe"
    result = automation_process.run(command_args([str(shell), "--mode=portable", f"--data={missing_data}", f"--shell-dir={missing}", "--open", str(document)]), capture_output=True, text=True)
    if result.returncode == 0 or missing_data.exists():
        raise RuntimeError("missing shell fell back to another host or created user data")
    print("CUTRANS_SHELL_MISSING_OK fallback=0 data_created=0")
    data = root / "shell data"
    empty_cwd = ensure_owned_data(root / "cwd without ini")
    # Dear ImGui's default save timer is five seconds. Keep the real GUI alive
    # beyond it so an accidental return to implicit cwd persistence is detected.
    start_and_verify(bootstrap, document, data, "portable", cleanup=False, settle_seconds=6.0, cwd=empty_cwd)
    lock_text = (data / "session/runtime.lock").read_text(encoding="utf-8")
    if "runtime_id=cutrans-vm" not in lock_text or "shell_id=" in lock_text:
        raise RuntimeError("an abruptly terminated desktop changed the committed Shell selection")
    if "C:\\" in lock_text or root.as_posix() in lock_text:
        raise RuntimeError("shell selection lock leaked a host path")
    print("CUTRANS_SHELL_LOCK_OK runtime=1 shell_uncommitted_after_abnormal=1 host_path=0")
    existing_cwd = ensure_owned_data(root / "cwd existing ini")
    (existing_cwd / "imgui.ini").write_bytes(b"; Cutrans verification sentinel: preserve unchanged.\n[Window][Cutrans verification]\nPos=123,234\nSize=321,234\nCollapsed=0\n")
    start_and_verify(bootstrap, document, root / "playback data", "portable", cleanup=False, playback_frames=4, settle_seconds=6.0, cwd=existing_cwd)
    start_and_verify(bootstrap, document, root / "asset data", "portable", cleanup=False, assets_demo=True)
    retain(root)


if __name__ == "__main__":
    main()

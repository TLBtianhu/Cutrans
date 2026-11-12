"""Explicit verification purpose and instance markers for owned test fixtures."""
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

from build_paths import OUTPUT
from product import identity
from verification_paths import check_root, ensure_owned_data

APPLICATIONS = frozenset({
    "cutrans.exe", "cutrans_vm.exe", "cutrans_bootstrap.exe", "cutrans_vm_host.exe",
    "cutrans_shell.exe", "cutrans_diag.exe", "cutrans_library_nanoui.exe",
})


def command_args(command: list[str]) -> list[str]:
    """Only native product entry points accept the product purpose argument."""
    values = [str(value) for value in command]
    if values and Path(values[0]).name.casefold() in APPLICATIONS and not any(
        value == "--purpose" or value.startswith("--purpose=") for value in values[1:]
    ):
        # The VM console recognizes its action only in argv[1]. Keep positional
        # command names and paired --open arguments in their original order.
        values.append("--purpose=verification")
    return values


def canonical_path(path: Path) -> str:
    return os.path.normcase(str(path.resolve()))


def context_record(path: Path, form: str) -> dict:
    record = json.loads(path.read_text(encoding="utf-8"))
    product = identity()
    if (record.get("format") != "cutrans-run-context/1"
        or record.get("product_id") != product["id"]
        or record.get("version") != product["version"]
        or record.get("form") != form
        or record.get("channel") not in {"development", "preview", "stable"}
        or record.get("services") != {"updates": False, "accounts": False, "telemetry": False}):
        raise RuntimeError(f"artifact context does not match the verification fixture: {path}")
    return record


def artifact_context(form: str, resource: Path | None = None) -> dict:
    candidates = []
    if resource is not None:
        # Runtime Packs have no execution identity of their own. Prefer their
        # containing application declaration before the generated output copy.
        resource = resource.resolve()
        for directory in (resource, resource.parent, resource.parent.parent):
            candidates.extend((directory / "cutrans-context.json", directory / "app/cutrans-context.json"))
    generated = {"development": OUTPUT / "bin", "portable": OUTPUT / "portable", "installed": OUTPUT / "installation"}
    if form not in generated:
        raise RuntimeError(f"unsupported verification form: {form}")
    candidates.append(generated[form] / "cutrans-context.json")
    for path in candidates:
        if path.is_file():
            # An adjacent declaration for another form cannot stand in for the
            # requested form; OUTPUT may also contain a development declaration.
            record = json.loads(path.read_text(encoding="utf-8"))
            if record.get("form") == form:
                return context_record(path, form)
    return {"channel": identity()["default_channel"]}


def mark_data(path: Path, form: str, resource: Path | None = None) -> Path:
    """Preseed ctypes data only beneath an already claimed verification case."""
    path = ensure_owned_data(path)
    marker = check_root(path / "cutrans-instance.json")
    expected = {"format": "cutrans-instance/1", "product_id": identity()["id"],
                "form": form, "channel": artifact_context(form, resource)["channel"],
                "purpose": "verification"}
    if marker.exists():
        if json.loads(marker.read_text(encoding="utf-8")) != expected:
            raise RuntimeError(f"verification instance identity mismatch: {marker}")
    else:
        if any(path.iterdir()):
            raise RuntimeError(f"refusing to mark nonempty unowned instance data: {path}")
        with marker.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(expected, indent=2) + "\n")
    return path


def copy_installed_context(app: Path) -> None:
    """Use the exact generated installed context and its matching VM manifest."""
    app = ensure_owned_data(app)
    context_record(OUTPUT / "installation/cutrans-context.json", "installed")
    for name in ("cutrans-context.json", "vm-pack.json"):
        destination = check_root(app / name)
        shutil.copy2(OUTPUT / "installation" / name, destination)

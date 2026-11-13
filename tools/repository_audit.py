"""Read-only source-package and repository checks; no builds or downloads.

This audits the literal root build.zig.zon paths, local build/Python inputs and
first-party Markdown file links. It also works in an extracted source package
without Git. It is a source-inventory check, not a substitute for Zig packaging,
compilation, dependency hashes or actual artifact/installer acceptance.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
from subprocess import SubprocessError
import sys
from urllib.parse import unquote

sys.dont_write_bytecode = True

import automation_process

ROOT = Path(__file__).resolve().parents[1]
FIRST_PARTY = ("apps", "assets", "bootstrap", "build_support", "config", "consoles", "docs",
    "packaging", "ports", "runtime", "shell", "uikit", "vne")
SKIP_DIRS = {".git", ".zig-cache", "zig-out", "zig-pkg", "scratch", "__pycache__", ".cutrans-dev"}
NATIVE_SUFFIXES = {".exe", ".dll", ".lib", ".pdb", ".obj", ".o", ".a", ".so", ".dylib", ".pyc", ".pyo"}
RESTORED_ROOTS = ("tools/zig", "tools/InnoSetup")
RETAINED_SDK_BINARIES = frozenset()
RESTORED_INPUTS = frozenset({"tools/zig/zig.exe", "tools/InnoSetup/ISCC.exe"})
GENERATED_INPUTS = {"config/startup.ccb": "config/compile_startup.py"}
GENERATED_MODULES = {}
# This archived prose used Markdown-looking notation for a conceptual tuple,
# rather than a filesystem destination. Keep the exact source/raw expression;
# other missing links, including other bare names, must still fail.
HISTORICAL_CONCEPT_LINKS = {("docs/memory/17-discussion-history-02.md", "四页树 id")}
PACKAGED_MARKDOWN_LINKS = {("packaging/README-portable.md", "licenses/Cutrans.txt"): "LICENSE"}


class AuditError(ValueError):
    pass


def portable_path(value):
    """Manifest entries are normalized, relative portable paths, never globs."""
    path = PurePosixPath(value)
    if not value or "\\" in value or ":" in value or path.is_absolute() or any(
            part in ("", ".", "..") for part in value.split("/")) or any(char in value for char in "*?[]\0"):
        raise AuditError(f"non-portable package path: {value!r}")
    return path.as_posix()


def is_reparse(info):
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def safe_path(root, relative):
    """Validate lexical ancestors before any read or resolution follows links."""
    path = root / portable_path(relative)
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            pass
        else:
            if is_reparse(info):
                raise AuditError(f"source path contains a link or junction: {current}")
    return path


def zig_tokens(text):
    """Enough lexical structure to inspect literals without executing Zig/ZON.

    Comments, quoted strings and multiline string bodies cannot fabricate a
    paths field or an import. Nonliteral paths declarations fail explicitly.
    """
    result, pos = [], 0
    while pos < len(text):
        char = text[pos]
        if char.isspace():
            pos += 1
        elif text.startswith("//", pos) or text.startswith("\\\\", pos):
            end = text.find("\n", pos)
            pos = len(text) if end < 0 else end + 1
        elif text.startswith("/*", pos):
            depth, pos = 1, pos + 2
            while depth and pos < len(text):
                if text.startswith("/*", pos):
                    depth, pos = depth + 1, pos + 2
                elif text.startswith("*/", pos):
                    depth, pos = depth - 1, pos + 2
                else:
                    pos += 1
            if depth:
                raise AuditError("unterminated source comment")
        elif char in ('"', "'"):
            start, quote = pos, char
            pos += 1
            while pos < len(text) and text[pos] != quote:
                pos += 2 if text[pos] == "\\" else 1
            if pos >= len(text):
                raise AuditError("unterminated source literal")
            pos += 1
            raw = text[start:pos]
            if quote == '"':
                try:
                    value = ast.literal_eval(raw)
                except (ValueError, SyntaxError):
                    # Arbitrary Zig text may use \u{...}; path literals must be
                    # plain/standard escaped text for this static audit.
                    value = raw[1:-1]
                result.append(("string", value))
            else:
                result.append(("char", raw))
        elif char.isalpha() or char == "_":
            end = pos + 1
            while end < len(text) and (text[end].isalnum() or text[end] == "_"):
                end += 1
            result.append(("name", text[pos:end]))
            pos = end
        else:
            result.append((char, char))
            pos += 1
    return result


def zon_paths(text):
    tokens = zig_tokens(text)
    starts = [index + 5 for index in range(len(tokens) - 4)
        if tokens[index:index + 5] == [(".", "."), ("name", "paths"), ("=", "="), (".", "."), ("{", "{")]]
    if len(starts) != 1:
        raise AuditError("expected one literal .paths = .{ ... } declaration")
    paths, index, expect_value = [], starts[0], True
    while index < len(tokens):
        kind, value = tokens[index]
        if kind == "}":
            if not paths:
                raise AuditError("empty package paths declaration")
            return paths
        if expect_value and kind == "string":
            paths.append(portable_path(value))
            expect_value = False
        elif not expect_value and kind == ",":
            expect_value = True
        else:
            raise AuditError("package paths must be a comma-separated list of literal strings")
        index += 1
    raise AuditError("unterminated package paths declaration")


def forbidden(relative, directory=False):
    parts = PurePosixPath(relative).parts
    if relative in GENERATED_INPUTS:
        return "generated source-tree output"
    if any(part.casefold() in {name.casefold() for name in SKIP_DIRS} for part in parts):
        return "generated/cache directory"
    if any(relative.casefold() == prefix.casefold() or relative.casefold().startswith(prefix.casefold() + "/") for prefix in RESTORED_ROOTS):
        return "restored toolchain/native directory"
    if not directory and PurePosixPath(relative).suffix.casefold() in NATIVE_SUFFIXES and relative not in RETAINED_SDK_BINARIES:
        return "native binary or Python bytecode"
    return None


def enumerate_files(root, relative, failures, *, inventory=False):
    """Do not enter excluded directories or reparse points, even on failure."""
    files, pending = set(), [relative]
    while pending:
        name = pending.pop()
        try:
            path = safe_path(root, name)
            info = path.lstat()
            directory = stat.S_ISDIR(info.st_mode)
            reason = forbidden(name, directory)
            if reason:
                if not inventory:
                    failures.append({"code": "excluded_package_input", "path": name, "detail": reason})
                continue
            if directory:
                pending.extend(f"{name}/{child.name}" for child in sorted(path.iterdir(), key=lambda item: item.name))
            elif stat.S_ISREG(info.st_mode):
                files.add(name)
            else:
                raise AuditError("source package input is not a regular file/directory")
        except (OSError, AuditError) as error:
            failures.append({"code": "unsafe_or_missing_path", "path": name, "detail": str(error)})
    return files


def first_party_files(root, failures):
    result = set()
    for name in (*FIRST_PARTY, "tools"):
        try:
            if safe_path(root, name).exists():
                result.update(enumerate_files(root, name, failures, inventory=True))
        except (OSError, AuditError) as error:
            failures.append({"code": "unsafe_source_directory", "path": name, "detail": str(error)})
    for item in root.iterdir():
        if item.name in {"LICENSE", ".gitignore", ".gitattributes"} or item.suffix.lower() in {".md", ".zig", ".zon", ".json", ".ps1"}:
            try:
                if safe_path(root, item.name).is_file():
                    result.add(item.name)
            except (OSError, AuditError) as error:
                failures.append({"code": "unsafe_source", "path": item.name, "detail": str(error)})
    return result


def local_path(root, base, value):
    path = Path(os.path.abspath(root / base / value))
    if not path.is_relative_to(root):
        raise AuditError(f"local dependency escapes source root: {value!r}")
    return path.relative_to(root).as_posix()


def zon_dependencies(text):
    """Local dependency name -> source path from literal dependency objects."""
    tokens, result = zig_tokens(text), {}
    for index in range(len(tokens) - 4):
        if (tokens[index][0] != "." or tokens[index + 1][0] != "name"
            or tokens[index + 2:index + 5] != [("=", "="), (".", "."), ("{", "{")]):
            continue
        name, cursor, depth = tokens[index + 1][1], index + 5, 1
        while cursor < len(tokens) and depth:
            if depth == 1 and tokens[cursor:cursor + 3] == [(".", "."), ("name", "path"), ("=", "=")] and cursor + 3 < len(tokens) and tokens[cursor + 3][0] == "string":
                result[name] = tokens[cursor + 3][1]
            if tokens[cursor][0] == "{":
                depth += 1
            elif tokens[cursor][0] == "}":
                depth -= 1
            cursor += 1
    return result


def zig_inputs(relative, text, dependencies=None):
    tokens, found = zig_tokens(text), []
    build_file = relative == "build.zig" or relative.startswith("build_support/")
    bindings = {"b": "."}
    if build_file:
        # A dependency .path is relative to that package, not Cutrans. Resolve
        # const zgui_dep = b.dependency("zgui", ...) against the root manifest.
        for index in range(len(tokens) - 7):
            if (tokens[index] == ("name", "const") and tokens[index + 1][0] == "name"
                and tokens[index + 2:index + 7] == [("=", "="), ("name", "b"), (".", "."), ("name", "dependency"), ("(", "(")]
                and tokens[index + 7][0] == "string"):
                dependency = tokens[index + 7][1]
                if dependency in (dependencies or {}):
                    bindings[tokens[index + 1][1]] = dependencies[dependency]
    for index in range(len(tokens) - 4):
        chunk = tokens[index:index + 5]
        if chunk[0][0] == "@" and chunk[1] in (("name", "import"), ("name", "embedFile")) and chunk[2][0] == "(" and chunk[3][0] == "string" and chunk[4][0] == ")":
            value = chunk[3][1]
            if chunk[1][1] == "embedFile" and value in GENERATED_MODULES:
                found.append((".", GENERATED_MODULES[value]))
            elif chunk[1][1] == "embedFile" or value.endswith(".zig"):
                found.append((str(PurePosixPath(relative).parent), value))
        if build_file and chunk[:3] == [(".", "."), ("name", "path"), ("(", "(")] and chunk[3][0] == "string" and chunk[4][0] == ")" and chunk[3][1]:
            receiver = tokens[index - 1][1] if index > 0 and tokens[index - 1][0] == "name" else None
            if receiver not in bindings:
                raise AuditError(f"unresolved local build path receiver: {receiver!r}")
            found.append((bindings[receiver], chunk[3][1]))
    if build_file:
        # Build tables pass source[0] to b.path at comptime. Include literal
        # array/table inputs and the three local path-taking build helpers.
        # A b.fmt runtime PATH string is neither of those input contexts.
        prefixes = FIRST_PARTY + ("tools", "third_party")
        braces, calls = [], []
        for index, (kind, value) in enumerate(tokens):
            if kind == "{":
                braces.append(index > 0 and tokens[index - 1][0] == ".")
            elif kind == "}":
                if braces:
                    braces.pop()
            elif kind == "(":
                calls.append(tokens[index - 1][1] if index > 0 and tokens[index - 1][0] == "name" else None)
            elif kind == ")":
                if calls:
                    calls.pop()
            elif kind == "string" and any(value.startswith(prefix + "/") for prefix in prefixes):
                if calls and calls[-1] == "fmt":
                    continue
                if ((braces and braces[-1]) or (calls and calls[-1] in {"verify", "finish", "addSource"})):
                    found.append((".", value.rstrip("/")))
    return found


def portable_projections(text):
    """Literal portable copies used to validate links authored for the output."""
    tokens, result = zig_tokens(text), {}
    for index in range(len(tokens) - 6):
        chunk = tokens[index:index + 7]
        if (chunk[0:2] == [(".", "."), ("{", "{")] and chunk[2][0] == "string" and chunk[3][0] == ","
            and chunk[4][0] == "string" and (chunk[5][0] == "}" or chunk[5:7] == [(",", ","), ("}", "}")])
            and chunk[4][1].startswith("portable/")):
            result[chunk[4][1][len("portable/"):]] = chunk[2][1]
    # Files.add(b.path(source), destination) is not a notice-table row.
    for index in range(len(tokens) - 12):
        chunk = tokens[index:index + 13]
        if (chunk[:8] == [("name", "portable_files"), (".", "."), ("name", "add"), ("(", "("),
            ("name", "b"), (".", "."), ("name", "path"), ("(", "(")]
            and chunk[8][0] == "string" and chunk[9:11] == [(")", ")"), (",", ",")]
            and chunk[11][0] == "string" and chunk[12][0] == ")"):
            result[chunk[11][1]] = chunk[8][1]
    return result


def python_inputs(root, relative, text):
    found = set()
    tree = ast.parse(text, filename=relative)
    stdlib = sys.stdlib_module_names | set(sys.builtin_module_names) | {"__future__"}
    for node in ast.walk(tree):
        names = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            names = [node.module] if node.module else [alias.name for alias in node.names]
        for name in names:
            first = name.split(".")[0]
            if first in stdlib:
                continue
            bases = [PurePosixPath(relative).parent, PurePosixPath("tools"), PurePosixPath(".")]
            candidates = [local_path(root, str(base), name.replace(".", "/") + suffix)
                for base in bases for suffix in (".py", "/__init__.py")]
            match = next((candidate for candidate in candidates if safe_path(root, candidate).is_file()), None)
            if match is None:
                raise AuditError(f"unresolved non-stdlib Python import {name!r} at line {node.lineno}")
            found.add(match)
    return found


def markdown_links(text):
    """File targets in inline/image links and reference definitions, sans code."""
    lines, fence = [], None
    for line in text.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            value = marker.group(1)
            if fence is None:
                fence = value
            elif value[0] == fence[0] and len(value) >= len(fence):
                fence = None
            continue
        if fence is None:
            lines.append(line)
    plain = re.sub(r"(`+).*?\1", "", "\n".join(lines))
    targets = []
    for match in re.finditer(r"\]\(\s*", plain):
        start = match.end()
        if start < len(plain) and plain[start] == "<":
            end = plain.find(">", start + 1)
            if end >= 0:
                targets.append({"target": plain[start + 1:end], "raw": plain[start:end + 1]})
        else:
            end, depth = start, 0
            while end < len(plain):
                char = plain[end]
                if char == "\\" and end + 1 < len(plain):
                    end += 2
                    continue
                if char == "(":
                    depth += 1
                elif char == ")":
                    if depth == 0:
                        break
                    depth -= 1
                elif char.isspace() and depth == 0:
                    break
                end += 1
            if end > start:
                closing = plain.find(")", end)
                raw = plain[start:closing] if closing >= 0 else plain[start:end]
                targets.append({"target": plain[start:end], "raw": raw.strip()})
    for match in re.finditer(r"(?m)^\s{0,3}\[[^\]\n]+\]:\s*(?:<([^>\n]+)>|(\S+))", plain):
        target = match.group(1) or match.group(2)
        targets.append({"target": target, "raw": target})
    return targets


def markdown_targets(text):
    return [link["target"] for link in markdown_links(text)]


def audit(root, *, git=True):
    root = Path(os.path.abspath(root))
    failures = []
    report = {"format": "cutrans-repository-audit/1", "root": str(root), "passed": False,
        "failures": failures, "retained_sdk_binaries": [], "restored_inputs": [], "generated_inputs": [],
        "markdown": {"files": 0, "local_links": 0, "historical_absolute_links": 0, "external_links": 0,
            "concept_links": [], "packaged_output_links": []},
        "limitations": ["Static literal input/file-link audit; does not execute Zig or inspect Markdown anchors",
            "Vendor Markdown is not navigation owned by this repository; dependency hashes are audited separately",
            "Native toolchain and product binaries are restored outside the source package"]}
    try:
        manifest = safe_path(root, "build.zig.zon")
        manifest_text = manifest.read_text(encoding="utf-8")
        paths = zon_paths(manifest_text)
    except (OSError, AuditError) as error:
        failures.append({"code": "invalid_package_manifest", "path": "build.zig.zon", "detail": str(error)})
        return report
    report["declared_paths"] = paths
    for name in GENERATED_INPUTS:
        try:
            if safe_path(root, name).exists():
                failures.append({"code": "generated_source_output_present", "path": name,
                    "detail": "generated bytes belong in the build cache even when untracked/unselected"})
        except (OSError, AuditError) as error:
            failures.append({"code": "unsafe_generated_output", "path": name, "detail": str(error)})
    selected, casefolded = set(), set()
    for name in paths:
        if name.casefold() in casefolded:
            failures.append({"code": "duplicate_package_path", "path": name, "detail": "duplicate portable identity"})
        casefolded.add(name.casefold())
        if any(prefix.casefold().startswith(name.casefold() + "/") for prefix in RESTORED_ROOTS):
            failures.append({"code": "broad_restored_root", "path": name, "detail": "would also package restored toolchains/native files"})
            continue
        declared_files = enumerate_files(root, name, failures)
        selected.update(declared_files)
        if not declared_files:
            try:
                if safe_path(root, name).is_dir():
                    failures.append({"code": "empty_declared_directory", "path": name,
                        "detail": "declaration selects no regular source files; Git archives cannot deliver empty directories"})
            except (OSError, AuditError):
                # Enumeration already records unsafe/missing input failures.
                pass
    inventory = first_party_files(root, failures)
    required = inventory | {"build.zig", "build.zig.zon", "README.md", "LICENSE", "dependencies.lock.json", ".gitignore"}
    try:
        lock = json.loads(safe_path(root, "dependencies.lock.json").read_text(encoding="utf-8"))
        if lock.get("format") != "cutrans-dependencies/1":
            raise AuditError("unsupported dependency source inventory format")
        # Match the retained, reviewed vendor trees, not only the entry files
        # referenced by the current Windows build branch. Their effective byte
        # hashes continue to belong to dependency_audit.py.
        for source in lock.get("sources", []):
            required.update(enumerate_files(root, portable_path(source["path"]), failures, inventory=True))
    except (OSError, AuditError, ValueError, KeyError, TypeError) as error:
        failures.append({"code": "invalid_dependency_inventory", "path": "dependencies.lock.json", "detail": str(error)})

    def need(name, source):
        if name in GENERATED_INPUTS:
            report["generated_inputs"].append({"path": name, "generator": GENERATED_INPUTS[name]})
            return need(GENERATED_INPUTS[name], source)
        if name in RESTORED_INPUTS:
            report["restored_inputs"].append({"path": name, "restore": "python tools/bootstrap.py"})
            return need("tools/bootstrap.py", source)
        required.add(name)
        try:
            path = safe_path(root, name)
            if not path.exists():
                failures.append({"code": "missing_local_input", "path": name, "detail": source})
            elif path.is_dir():
                # Directory inputs must include all their current source files.
                required.update(enumerate_files(root, name, failures))
            elif name not in selected:
                failures.append({"code": "unpackaged_local_input", "path": name, "detail": source})
        except (OSError, AuditError) as error:
            failures.append({"code": "unsafe_local_input", "path": name, "detail": f"{source}: {error}"})

    for relative in sorted(inventory):
        try:
            if relative.endswith(".zig"):
                text = safe_path(root, relative).read_text(encoding="utf-8")
                for base, value in zig_inputs(relative, text, zon_dependencies(manifest_text)):
                    need(local_path(root, base, value), relative)
            elif relative.endswith(".py"):
                for name in python_inputs(root, relative, safe_path(root, relative).read_text(encoding="utf-8")):
                    need(name, relative)
        except (OSError, AuditError, SyntaxError, UnicodeError) as error:
            failures.append({"code": "unreadable_source_inputs", "path": relative, "detail": str(error)})

    # Resolve local package dependencies recursively, including sibling vendor
    # dependencies. Remote/lazy dependencies stay under the bootstrap/lock audit.
    pending, seen = ["build.zig.zon"], set()
    while pending:
        relative = pending.pop()
        if relative in seen:
            continue
        seen.add(relative)
        try:
            tokens = zig_tokens(safe_path(root, relative).read_text(encoding="utf-8"))
            for index in range(len(tokens) - 3):
                if tokens[index:index + 3] != [(".", "."), ("name", "path"), ("=", "=")] or tokens[index + 3][0] != "string":
                    continue
                dependency = local_path(root, str(PurePosixPath(relative).parent), tokens[index + 3][1])
                for leaf in ("build.zig", "build.zig.zon"):
                    need(f"{dependency}/{leaf}", relative)
                pending.append(f"{dependency}/build.zig.zon")
        except (OSError, AuditError, UnicodeError) as error:
            failures.append({"code": "invalid_local_dependency", "path": relative, "detail": str(error)})

    try:
        projections = portable_projections(safe_path(root, "build.zig").read_text(encoding="utf-8"))
    except (OSError, AuditError, UnicodeError) as error:
        projections = {}
        failures.append({"code": "invalid_pack_projections", "path": "build.zig", "detail": str(error)})
    for relative in sorted(inventory):
        if not relative.lower().endswith(".md"):
            continue
        report["markdown"]["files"] += 1
        try:
            links = markdown_links(safe_path(root, relative).read_text(encoding="utf-8"))
            for link in links:
                target = link["target"]
                if (relative, link["raw"]) in HISTORICAL_CONCEPT_LINKS:
                    report["markdown"]["concept_links"].append({"source": relative, "expression": link["raw"]})
                    continue
                decoded = unquote(re.sub(r"\\([ ()])", r"\1", target))
                if re.match(r"^[A-Za-z]:[\\/]", decoded) or decoded.startswith(("/", "\\\\")) or decoded.lower().startswith("file:"):
                    report["markdown"]["historical_absolute_links"] += 1
                    continue
                if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", decoded):
                    report["markdown"]["external_links"] += 1
                    continue
                path = decoded.split("#", 1)[0].split("?", 1)[0]
                if not path:
                    continue
                report["markdown"]["local_links"] += 1
                projected_source = PACKAGED_MARKDOWN_LINKS.get((relative, path))
                if projected_source is not None:
                    if projections.get("README.md") != relative or projections.get(path) != projected_source:
                        failures.append({"code": "missing_pack_projection", "path": path,
                            "detail": f"{relative} requires actual portable copies of README.md and {projected_source}"})
                    else:
                        report["markdown"]["packaged_output_links"].append({"document": relative,
                            "target": path, "source": projected_source})
                        need(projected_source, f"portable output link in {relative}")
                    continue
                need(local_path(root, str(PurePosixPath(relative).parent), path), f"Markdown link in {relative}")
        except (OSError, AuditError, UnicodeError) as error:
            failures.append({"code": "invalid_markdown_link", "path": relative, "detail": str(error)})

    for name in sorted(required - selected):
        # Directory and generated/restored declarations are covered through
        # their inputs above; only regular inventory/source files belong here.
        try:
            path = safe_path(root, name)
            if path.is_file() or not path.exists():
                failures.append({"code": "unpackaged_source", "path": name, "detail": "required source/tool/document absent from package selection"})
        except (OSError, AuditError) as error:
            failures.append({"code": "unsafe_required_source", "path": name, "detail": str(error)})
    for name in sorted(selected & RETAINED_SDK_BINARIES):
        report["retained_sdk_binaries"].append({"path": name,
            "sha256": hashlib.sha256(safe_path(root, name).read_bytes()).hexdigest(), "policy": "exact pinned SDK exception"})
    report["git"] = {"checked": False, "reason": "source archive/no .git"}
    git_present = False
    if git:
        try:
            git_present = safe_path(root, ".git").exists()
        except (OSError, AuditError) as error:
            failures.append({"code": "unsafe_git_metadata", "path": ".git", "detail": str(error)})
    if git_present:
        try:
            result = automation_process.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True, timeout=20)
            tracked = [value.decode("utf-8") for value in result.stdout.split(b"\0") if value]
            report["git"] = {"checked": True, "tracked_files": len(tracked),
                "untracked_selected_sources": sorted(selected - set(tracked)),
                "untracked_policy": "reported for review; staging is not a prerequisite for a development audit"}
            for name in tracked:
                reason = forbidden(name)
                if reason:
                    failures.append({"code": "tracked_generated_file", "path": name, "detail": reason})
        except (OSError, ValueError, RuntimeError, SubprocessError) as error:
            failures.append({"code": "git_inventory_failed", "path": ".git", "detail": str(error)})
    elif not git:
        report["git"] = {"checked": False, "reason": "explicit caller policy"}
    report["selected_files"] = len(selected)
    report["required_files"] = len(required)
    report["local_dependency_packages"] = len(seen) - 1
    report["restored_inputs"] = sorted({value["path"]: value for value in report["restored_inputs"]}.values(), key=lambda item: item["path"])
    report["generated_inputs"] = sorted({value["path"]: value for value in report["generated_inputs"]}.values(), key=lambda item: item["path"])
    report["passed"] = not failures
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="checkout or extracted source-package root")
    parser.add_argument("--json", type=Path, help="write a new evidence file; existing reports are never overwritten")
    args = parser.parse_args()
    report = audit(args.root)
    if args.json:
        with args.json.open("x", encoding="utf-8") as output:
            json.dump(report, output, ensure_ascii=False, indent=2)
            output.write("\n")
    for failure in report["failures"]:
        print(f"{failure['code']}: {failure['path']}: {failure['detail']}")
    if report["passed"]:
        print(f"CUTRANS_REPOSITORY_AUDIT_OK selected={report['selected_files']} required={report['required_files']} "
            f"markdown={report['markdown']['files']} local_links={report['markdown']['local_links']} "
            f"retained_sdk_binaries={len(report['retained_sdk_binaries'])} git={int(report['git']['checked'])}")
        return 0
    print(f"CUTRANS_REPOSITORY_AUDIT_FAILED failures={len(report['failures'])}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

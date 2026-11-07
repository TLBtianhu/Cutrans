"""Verify real Windows console state without displaying a test window."""
from __future__ import annotations

import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

import automation_process as process
from verification_paths import claim, default_root, retain

TOOLS = Path(__file__).resolve().parent
PYTHON = str(Path(sys.executable).with_name("python.exe")) if os.name == "nt" else sys.executable
STATE = '''import ctypes,json,os
k=ctypes.WinDLL("kernel32",use_last_error=True)
k.GetConsoleWindow.restype=ctypes.c_void_p
window=k.GetConsoleWindow()
pids=(ctypes.c_uint32*64)()
count=k.GetConsoleProcessList(pids,64)
value={"pid":os.getpid(),"window":window or 0,"visible":bool(ctypes.windll.user32.IsWindowVisible(ctypes.c_void_p(window or 0))),"processes":list(pids)[:min(count,64)]}
print(json.dumps(value))
'''


class AutomationPolicy(unittest.TestCase):
    def test_all_python_automation_uses_the_shared_launcher(self):
        methods = {"run", "Popen", "call", "check_output", "check_call"}
        for path in TOOLS.glob("*.py"):
            if path.name == "automation_process.py" or path.name.startswith("test_"):
                continue
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                    self.assertFalse(isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess"
                                     and node.func.attr in methods, f"direct console spawn: {path}:{node.lineno}")


@unittest.skipUnless(os.name == "nt", "Windows console allocation")
class WindowsConsole(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = claim(default_root("quiet-process"))
        retain(cls.root)
        cls.evidence = {}

    @classmethod
    def tearDownClass(cls):
        (cls.root / "console-state.json").write_text(json.dumps(cls.evidence, indent=2) + "\n", encoding="utf-8")
        print(f"Console state evidence: {cls.root}")

    def test_direct_children_have_no_console(self):
        result = process.run([PYTHON, "-c", STATE], capture_output=True, text=True, check=True)
        state = json.loads(result.stdout)
        self.assertEqual(state["window"], 0)
        self.assertFalse(state["visible"])
        self.evidence["direct"] = state

    def test_hidden_build_console_is_inherited_by_unmodified_grandchild(self):
        # Deliberately exercise the builder's default spawn semantics in a
        # child string, with no console flags on the grandchild itself.
        code = f'''import subprocess,sys,json
exec({STATE!r})
result=subprocess.run([sys.executable,"-c",{STATE!r}],capture_output=True,text=True,check=True)
print(result.stdout,end="")
'''
        result = process.run_console_tree([PYTHON, "-c", code], capture_output=True, text=True, check=True)
        parent, child = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertNotEqual(parent["window"], 0)
        self.assertFalse(parent["visible"])
        self.assertFalse(child["visible"])
        self.assertIn(parent["pid"], child["processes"])
        self.evidence["hidden_tree"] = {"parent": parent, "child": child}

    def test_streams_cwd_environment_and_exit_code_are_preserved(self):
        code = "import os,sys; print(os.getcwd()); print(os.environ['CUTRANS_QUIET_SENTINEL']); print(sys.stdin.read()); print('diagnostic',file=sys.stderr); sys.exit(19)"
        result = process.run([PYTHON, "-c", code], input="retained input", capture_output=True, text=True,
                             cwd=self.root, env=dict(os.environ, CUTRANS_QUIET_SENTINEL="test-only"))
        self.assertEqual(result.returncode, 19)
        self.assertEqual(result.stdout.splitlines(), [str(self.root), "test-only", "retained input"])
        self.assertEqual(result.stderr.strip(), "diagnostic")
        self.evidence["streams_exit"] = {"exit": result.returncode, "stderr": result.stderr}

    def test_popen_and_check_output_do_not_open_consoles(self):
        child = process.Popen([PYTHON, "-c", STATE], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        stdout, stderr = child.communicate(timeout=10)
        self.assertEqual(child.returncode, 0, stderr)
        self.assertEqual(json.loads(stdout)["window"], 0)
        self.assertEqual(json.loads(process.check_output([PYTHON, "-c", STATE], text=True))["window"], 0)
        self.assertEqual(process.call([PYTHON, "-c", "raise SystemExit(17)"]), 17)

    def test_nested_runner_preserves_inherited_output(self):
        code = f'''import sys
sys.path.insert(0,{str(TOOLS)!r})
import automation_process as process
raise SystemExit(process.call([sys.executable,"-c",{(STATE + "import sys; print('nested diagnostic',file=sys.stderr); raise SystemExit(17)")!r}]))
'''
        result = process.run([PYTHON, "-c", code], capture_output=True, text=True)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(json.loads(result.stdout)["window"], 0)
        self.assertEqual(result.stderr.strip(), "nested diagnostic")
        self.evidence["nested_output"] = {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


if __name__ == "__main__":
    unittest.main()

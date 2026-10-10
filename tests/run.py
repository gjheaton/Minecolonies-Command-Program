#!/usr/bin/env python3
"""Run deterministic Lua 5.2 simulations of the CC:Tweaked supply network."""
from pathlib import Path
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, "/workspace/.onboarding/python")
try:
    from lupa.lua52 import LuaRuntime
except ImportError:
    sys.exit("Lua 5.2 runtime missing. Install lupa==2.6 or use the published cloud environment.")

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().TEST_ROOT = str(ROOT)
lua.execute("package.path = TEST_ROOT .. '/?.lua;' .. TEST_ROOT .. '/?/init.lua;' .. package.path")
compile_file = lua.eval("function(source, name) local chunk, err = load(source, '@' .. name, 't'); return chunk ~= nil, err end")
errors = []
for path in sorted(ROOT.rglob("*.lua")):
    if ".git" in path.parts:
        continue
    ok, error = compile_file(path.read_text(), str(path.relative_to(ROOT)))
    if not ok:
        errors.append(f"{path.relative_to(ROOT)}: {error}")
if errors:
    sys.exit("Lua compilation failed:\n" + "\n".join(errors))
print("Lua 5.2: all Lua sources compile", flush=True)
try:
    lua.execute("require('tests.support')")
    for suite in ("tests.test_io", "tests.test_client", "tests.test_network", "tests.test_diagnostics", "tests.test_ui", "tests.test_displays", "tests.test_telemetry", "tests.test_runtime", "tests.test_runtime_displays", "tests.test_setup", "tests.test_devices", "tests.test_peripheral_picker", "tests.test_connections"):
        lua.execute(f"require('{suite}')")
    passed, failed = lua.eval("Test.run()")
except Exception as error:
    sys.exit(f"Simulation could not run: {error}")
print(f"Simulation: {passed} passed, {failed} failed", flush=True)
environment = os.environ.copy()
environment["PYTHONPATH"] = "/workspace/.onboarding/python" + os.pathsep + environment.get("PYTHONPATH", "")
python_failed = False
for suite in ("test_installer.py", "test_updater.py"):
    result = subprocess.run([sys.executable, str(ROOT / "tests" / suite)], cwd=ROOT, env=environment)
    python_failed = python_failed or result.returncode != 0
sys.exit(1 if failed or python_failed else 0)

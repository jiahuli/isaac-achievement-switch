"""离线跑 main.lua 的逻辑测试（用真实 Lua 解释器 + 假到不能再假的以撒 API）。

用法（在仓库任意位置执行都行）：
    python tools/run_tests.py
"""
import os
import pathlib
import sys

try:
    import lupa
except ImportError:
    sys.exit("需要 lupa：python -m pip install lupa")

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = [ROOT / "tools" / "mock_env.lua", ROOT / "tools" / "test_main.lua"]

for path in FILES:
    if not path.exists():
        sys.exit("找不到 " + str(path))

# test_main.lua 里用相对路径加载 mod，所以把工作目录切到仓库根
os.chdir(ROOT)

runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
# 交给 Lua 自己加载脚本（dofile），Python 侧不做任何代码求值
lua_dofile = runtime.globals().dofile

for path in FILES:
    lua_dofile(str(path))

print("全部通过。")

"""把 mod 目录打包成可以直接丢进 mods 的成品 zip。

用法（在仓库任意位置执行）：
    python tools/pack.py

产物：仓库根目录下的 achievement_switch-v<版本>.zip
      解压后是 achievement_switch/ 文件夹，整个丢进 <游戏>/mods/ 即可。

刻意只打 mod 自己需要的文件（main.lua / metadata.xml / thumb.png）：
保证不会把开发用的临时文件（.mimosa 扫描状态、日志、data 等）混进发布包里。
"""
import os
import pathlib
import re
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD_DIR = ROOT / "achievement_switch"
PAYLOAD = ("main.lua", "metadata.xml", "thumb.png")


def read_version() -> str:
    text = (MOD_DIR / "main.lua").read_text(encoding="utf-8")
    match = re.search(r'MOD_VERSION\s*=\s*"([^"]+)"', text)
    return match.group(1) if match else "0.0.0"


def main() -> None:
    os.chdir(ROOT)
    for name in PAYLOAD:
        if not (MOD_DIR / name).is_file():
            raise SystemExit("缺少文件：" + str(MOD_DIR / name))

    version = read_version()
    out = ROOT / f"achievement_switch-v{version}.zip"
    if out.exists():
        out.unlink()

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in PAYLOAD:
            zf.write(MOD_DIR / name, f"achievement_switch/{name}")

    print(f"已打包 {out.name}")
    with zipfile.ZipFile(out) as zf:
        for info in zf.infolist():
            print(f"  {info.filename}  ({info.file_size} bytes)")


if __name__ == "__main__":
    main()

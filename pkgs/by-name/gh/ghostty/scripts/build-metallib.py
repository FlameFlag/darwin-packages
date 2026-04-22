#!/usr/bin/env python3
"""
Build Ghostty.metallib from the upstream shaders.metal source using Apple's
proprietary Metal compiler (invoked via xcrun).

Must be run on macOS with Xcode / Command Line Tools installed, since the
Metal toolchain is not available under Nix. Intended to be re-run whenever
the Ghostty version or the shader source changes; the resulting metallib
is committed alongside package.nix.

Usage:
  build-metallib.py                       # auto-detect version from package.nix
                                          # and fetch the matching tag
  build-metallib.py --source PATH         # use a local ghostty checkout
  build-metallib.py --output PATH         # override output path
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
PKG_DIR = HERE.parent
SHADER_REL = "src/renderer/shaders/shaders.metal"
DEFAULT_OUTPUT = PKG_DIR / "Ghostty.metallib"
MIN_MACOS = "10.14"


def read_version() -> str:
    text = (PKG_DIR / "package.nix").read_text()
    m = re.search(r'version\s*=\s*"([^"]+)"', text)
    if not m:
        sys.exit("could not find version = \"...\" in package.nix")
    return m.group(1)


def fetch_source(version: str, dest: pathlib.Path) -> pathlib.Path:
    url = "https://github.com/ghostty-org/ghostty.git"
    tag = f"v{version}"
    print(f"cloning {url} @ {tag} into {dest}")
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", tag, url, str(dest)],
        check=True,
    )
    return dest


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def compile_metallib(shader: pathlib.Path, output: pathlib.Path) -> None:
    with tempfile.TemporaryDirectory() as td:
        ir = pathlib.Path(td) / "ghostty.ir"
        run([
            "xcrun", "-sdk", "macosx", "metal",
            "-std=metal3.0",
            "-o", str(ir), "-c", str(shader),
            f"-mmacos-version-min={MIN_MACOS}",
        ])
        output.parent.mkdir(parents=True, exist_ok=True)
        run([
            "xcrun", "-sdk", "macosx", "metallib",
            "-o", str(output), str(ir),
        ])


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--source", type=pathlib.Path,
                   help="path to a local ghostty checkout")
    p.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT,
                   help=f"output metallib path (default: {DEFAULT_OUTPUT})")
    args = p.parse_args()

    if sys.platform != "darwin":
        sys.exit("metal compilation requires macOS with Xcode installed")
    if shutil.which("xcrun") is None:
        sys.exit("xcrun not on PATH; install Xcode Command Line Tools")

    if args.source is not None:
        src_root = args.source.resolve()
    else:
        version = read_version()
        tmp_root = pathlib.Path(tempfile.mkdtemp(prefix="ghostty-metallib-"))
        src_root = fetch_source(version, tmp_root / "ghostty")

    shader = src_root / SHADER_REL
    if not shader.is_file():
        sys.exit(f"shader source not found at {shader}")

    compile_metallib(shader, args.output.resolve())
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()

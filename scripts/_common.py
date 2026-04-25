"""Shared helpers for the package scripts."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FORMAL_ARG_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_'-]*)")
TOP_LEVEL_ARGS_RE = re.compile(r"\A\s*\{(?P<body>.*?)\}\s*:", re.DOTALL)


def gha(kind: str, msg: str, file: str | None = None) -> None:
    attrs = f" file={file}" if file else ""
    print(f"::{kind}{attrs}::{msg}", flush=True)


@contextmanager
def gha_group(name: str) -> Iterator[None]:
    print(f"::group::{name}", flush=True)
    try:
        yield
    finally:
        print("::endgroup::", flush=True)


def gha_output(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as f:
        f.write(f"{key}={value}\n")


def gha_summary(content: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a") as f:
        f.write(content)


def run(
    cmd: Sequence[str | Path],
    *,
    cwd: Path | None = None,
    check: bool = False,
    capture: bool = False,
    env_extra: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Thin wrapper around subprocess.run with str/Path coercion."""
    env = {**os.environ, **env_extra} if env_extra else None
    return subprocess.run(
        [str(c) for c in cmd],
        cwd=str(cwd) if cwd else None,
        check=check,
        capture_output=capture,
        text=True,
        env=env,
    )


def nix_eval(expr: str, check: bool = False) -> str:
    """Evaluate a Nix expression with --impure --raw. Empty string on failure unless check=True."""
    r = run(["nix", "eval", "--impure", "--raw", "--expr", expr], capture=True, check=check)
    return r.stdout.strip() if r.returncode == 0 else ""


def nix_flake_attr(pkg: str, attr: str, system: str) -> str:
    """Evaluate a package attribute from this flake. Empty string on failure."""
    r = run(
        ["nix", "eval", "--impure", "--raw", f".#legacyPackages.{system}.{pkg}.{attr}"],
        cwd=REPO_ROOT,
        capture=True,
    )
    return r.stdout.strip() if r.returncode == 0 else ""


def nix_string_attr(nix_file: Path, key: str) -> str:
    """Return a simple `key = "value";` attribute from a Nix file."""
    match = re.search(
        rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"\s*;',
        nix_file.read_text(),
        re.M,
    )
    return match.group(1) if match else ""


def nix_top_level_formal_args(nix_file: Path) -> set[str]:
    """Return the function argument names from a simple `{ ... }:` Nix file."""
    content = re.sub(r"#.*", "", nix_file.read_text())
    match = TOP_LEVEL_ARGS_RE.match(content)
    if not match:
        return set()

    args: set[str] = set()
    for item in match.group("body").split(","):
        if arg_match := FORMAL_ARG_RE.match(item):
            args.add(arg_match.group(1))
    return args


@contextmanager
def pkg_wrapper(nix_file: Path, *, rec: bool = False) -> Iterator[Path]:
    """Yield a temporary wrapper.nix that callPackages the given package.nix.

    rec=False: `(pkgs.callPackage <nix_file> {})`
    rec=True:  `rec { pkg = pkgs.callPackage <nix_file> {}; }` (needed by nix-update)

    The file may be overwritten by the caller mid-use; the tempdir is cleaned
    up on exit.
    """
    with tempfile.TemporaryDirectory(prefix="nix-update-") as td:
        wrapper = Path(td) / "wrapper.nix"
        if rec:
            wrapper.write_text(
                "{ pkgs ? import <nixpkgs> {} }:\n"
                "rec {\n"
                f"  pkg = pkgs.callPackage {nix_file} {{}};\n"
                "}\n"
            )
        else:
            wrapper.write_text(
                f"let pkgs = import <nixpkgs> {{}}; in (pkgs.callPackage {nix_file} {{}})\n"
            )
        yield wrapper

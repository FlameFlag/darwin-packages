"""Shared helpers for the package scripts."""

from __future__ import annotations

import os
import subprocess
import tempfile
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


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

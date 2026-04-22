#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: [ ps.rich ps.tabulate ])"
"""Print a GitHub-flavored markdown table of every package under pkgs/by-name.

Invoked by the cog block in README.md. Run `cog -r README.md` to refresh,
or `cog --check README.md` to verify in CI.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

from rich.console import Console
from rich.progress import track
from tabulate import tabulate

from _common import REPO_ROOT as ROOT
from _common import nix_eval

_err = Console(stderr=True)

BY_NAME = ROOT / "pkgs" / "by-name"
SYSTEM = nix_eval("builtins.currentSystem", check=True)


def nix_attr(pkg: str, attr: str) -> str:
    r = subprocess.run(
        ["nix", "eval", "--impure", "--raw",
         f".#legacyPackages.{SYSTEM}.{pkg}.{attr}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    return r.stdout.strip() if r.returncode == 0 else ""


def scrape(pkgfile: Path, key: str) -> str:
    m = re.search(
        rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"\s*;',
        pkgfile.read_text(), re.M,
    )
    return m.group(1) if m else ""


def rows() -> list[list[str]]:
    out = []
    for f in track(
        sorted(BY_NAME.glob("*/*/package.nix")),
        description="Evaluating packages",
        console=_err,
    ):
        name = f.parent.name
        version = nix_attr(name, "version") or scrape(f, "version")
        desc = nix_attr(name, "meta.description") or scrape(f, "description")
        link = f.parent.relative_to(ROOT).as_posix()
        out.append([f"[`{name}`]({link})", f"`{version or '?'}`", desc])
    return out


if __name__ == "__main__":
    print(tabulate(
        rows(),
        headers=["Package", "Version", "Description"],
        tablefmt="github",
    ))

#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: [ ps.rich ps.tabulate ])"
"""Print a GitHub-flavored markdown table of every package under pkgs/by-name.

Invoked by the cog block in README.md. Run `cog -r README.md` to refresh,
or `cog --check README.md` to verify in CI.
"""

from __future__ import annotations

from rich.console import Console
from rich.progress import track
from tabulate import tabulate

from _common import REPO_ROOT as ROOT
from _common import nix_eval, nix_flake_attr, nix_string_attr

_err = Console(stderr=True)

BY_NAME = ROOT / "pkgs" / "by-name"
SYSTEM = nix_eval("builtins.currentSystem", check=True)


def rows() -> list[list[str]]:
    out = []
    for f in track(
        sorted(BY_NAME.glob("*/*/package.nix")),
        description="Evaluating packages",
        console=_err,
    ):
        name = f.parent.name
        version = nix_flake_attr(name, "version", SYSTEM) or nix_string_attr(f, "version")
        desc = nix_flake_attr(name, "meta.description", SYSTEM) or nix_string_attr(f, "description")
        link = f.parent.relative_to(ROOT).as_posix()
        out.append([f"[`{name}`]({link})", f"`{version or '?'}`", desc])
    return out


if __name__ == "__main__":
    print(
        tabulate(
            rows(),
            headers=["Package", "Version", "Description"],
            tablefmt="github",
        )
    )

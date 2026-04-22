#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: [ ps.typer ps.rich ])" git
"""Emit the list of by-name packages touched between two git revisions.

Used by the build-packages CI workflow. A change to any top-level infra file
(flake.nix, flake.lock, default.nix, the workflow itself) rebuilds every
package; otherwise only the directories under pkgs/by-name/<shard>/<pkg>/
that still exist after the diff are emitted.

Writes `packages=<json>` and `has_packages=<bool>` to $GITHUB_OUTPUT when
running in Actions, and prints the JSON list to stdout either way.
"""

from __future__ import annotations

import json
from pathlib import Path

import typer

from _common import REPO_ROOT, gha_output, run

INFRA_FILES = {
    "flake.nix",
    "flake.lock",
    "default.nix",
    ".github/workflows/build-packages.yaml",
}

BY_NAME = Path("pkgs/by-name")
ZERO_SHA = "0" * 40

app = typer.Typer(add_completion=False, help=__doc__)


def git_diff_files(base: str, head: str) -> list[str]:
    r = run(["git", "diff", "--name-only", base, head], cwd=REPO_ROOT, capture=True, check=True)
    return [line for line in r.stdout.splitlines() if line]


def resolve_base(base: str, head: str) -> str:
    """Fall back to HEAD^ for initial pushes where base is empty or all-zero."""
    if base and base != ZERO_SHA:
        return base
    r = run(["git", "rev-parse", f"{head}^"], cwd=REPO_ROOT, capture=True)
    return r.stdout.strip() if r.returncode == 0 else head


def all_packages() -> list[str]:
    return sorted(p.parent.name for p in (REPO_ROOT / BY_NAME).glob("*/*/package.nix"))


def changed_packages(files: list[str]) -> list[str]:
    pkgs: set[str] = set()
    for f in files:
        parts = Path(f).parts
        if len(parts) >= 4 and parts[0] == "pkgs" and parts[1] == "by-name":
            pkgs.add(parts[3])
    # Drop deletions: only keep packages whose dir still exists.
    return sorted(p for p in pkgs if any((REPO_ROOT / BY_NAME).glob(f"*/{p}/package.nix")))


@app.command()
def main(
    base: str = typer.Option(..., envvar="BASE_SHA", help="Base revision to diff from"),
    head: str = typer.Option(..., envvar="HEAD_SHA", help="Head revision to diff to"),
) -> None:
    base = resolve_base(base, head)
    print(f"Diffing {base}..{head}")

    files = git_diff_files(base, head)
    if any(f in INFRA_FILES for f in files):
        print("Infra file changed, building all packages")
        pkgs = all_packages()
    else:
        pkgs = changed_packages(files)

    payload = json.dumps(pkgs)
    print(f"Packages: {payload}")

    gha_output("packages", payload)
    gha_output("has_packages", "true" if pkgs else "false")


if __name__ == "__main__":
    app()

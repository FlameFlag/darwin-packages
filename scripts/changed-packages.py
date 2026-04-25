#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: [ ps.typer ps.rich ])" git
"""Emit the list of by-name packages touched between two git revisions.

Used by the build-packages CI workflow. A change to any top-level infra file
(flake.nix, flake.lock, default.nix, the workflow itself) rebuilds every
package; otherwise the directories under pkgs/by-name/<shard>/<pkg>/ that
still exist after the diff are emitted, along with any local packages that
depend on them.

Writes `packages=<json>` and `has_packages=<bool>` to $GITHUB_OUTPUT when
running in Actions, and prints the JSON list to stdout either way.
"""

from __future__ import annotations

import json
import re
from collections import defaultdict, deque
from pathlib import Path

import typer

from _common import REPO_ROOT, gha_output, run

INFRA_FILES = {
    "flake.nix",
    "flake.lock",
    "default.nix",
    ".github/workflows/build-packages.yaml",
    "scripts/_common.py",
    "scripts/changed-packages.py",
}
INFRA_PREFIXES = (".github/actions/setup-nix/",)

BY_NAME = Path("pkgs/by-name")
ZERO_SHA = "0" * 40
FORMAL_ARG_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_'-]*)")
TOP_LEVEL_ARGS_RE = re.compile(r"\A\s*\{(?P<body>.*?)\}\s*:", re.DOTALL)

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


def is_infra_file(path: str) -> bool:
    return path in INFRA_FILES or any(path.startswith(prefix) for prefix in INFRA_PREFIXES)


def package_nix_files() -> dict[str, Path]:
    return {p.parent.name: p for p in (REPO_ROOT / BY_NAME).glob("*/*/package.nix")}


def existing_packages(pkgs: set[str]) -> list[str]:
    package_files = package_nix_files()
    return sorted(p for p in pkgs if p in package_files)


def top_level_formal_args(nix_file: Path) -> set[str]:
    """Return the function argument names from a simple `{ ... }:` package.nix."""
    content = re.sub(r"#.*", "", nix_file.read_text())
    match = TOP_LEVEL_ARGS_RE.match(content)
    if not match:
        return set()

    args: set[str] = set()
    for item in match.group("body").split(","):
        if arg_match := FORMAL_ARG_RE.match(item):
            args.add(arg_match.group(1))
    return args


def local_dependency_graph() -> dict[str, set[str]]:
    package_files = package_nix_files()
    package_names = set(package_files)
    return {
        package: top_level_formal_args(nix_file) & package_names
        for package, nix_file in package_files.items()
    }


def include_local_dependents(pkgs: list[str]) -> list[str]:
    """Expand changed packages to include packages that consume them."""
    reverse_deps: defaultdict[str, set[str]] = defaultdict(set)
    for package, deps in local_dependency_graph().items():
        for dep in deps:
            reverse_deps[dep].add(package)

    expanded = set(pkgs)
    queue = deque(pkgs)
    while queue:
        package = queue.popleft()
        for dependent in reverse_deps[package]:
            if dependent not in expanded:
                expanded.add(dependent)
                queue.append(dependent)

    return sorted(expanded)


def changed_packages(files: list[str]) -> list[str]:
    pkgs: set[str] = set()
    for f in files:
        parts = Path(f).parts
        if len(parts) >= 4 and parts[0] == "pkgs" and parts[1] == "by-name":
            pkgs.add(parts[3])
    # Drop deletions: only keep packages whose dir still exists.
    return include_local_dependents(existing_packages(pkgs))


@app.command()
def main(
    base: str = typer.Option(..., envvar="BASE_SHA", help="Base revision to diff from"),
    head: str = typer.Option(..., envvar="HEAD_SHA", help="Head revision to diff to"),
) -> None:
    base = resolve_base(base, head)
    print(f"Diffing {base}..{head}")

    files = git_diff_files(base, head)
    if any(is_infra_file(f) for f in files):
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

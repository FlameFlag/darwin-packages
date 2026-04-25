#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p "python3.withPackages (ps: [ ps.typer ps.rich ])" nix-update git nix
"""Update by-name nix packages.

Subcommands:
  pkg <path>  Update a single package.nix. Dispatches on passthru.updateScript:
                string -> build as shell-script-bin and execute
                path   -> execute the file directly
                absent -> fall back to nix-update
  all         Walk pkgs/by-name, update each fetchable derivation, verify with
              `nix build`, and commit `<pkg>: bump` per package. Reverts the
              working tree on any failure.
"""

from __future__ import annotations

import contextlib
import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import typer

from _common import (
    REPO_ROOT,
    gha,
    gha_group,
    gha_output,
    gha_summary,
    nix_eval,
    pkg_wrapper,
    run,
)

app = typer.Typer(add_completion=False, help=__doc__)


def log_error(msg: str, file: str | None = None) -> None:
    gha("error", msg, file)


def log_info(msg: str) -> None:
    gha("debug", msg)


def log_notice(msg: str, file: str | None = None) -> None:
    gha("notice", msg, file)


@dataclass(slots=True, frozen=True)
class Metadata:
    owner: str
    repo: str
    update_script_kind: Literal["", "string", "path"]

    @property
    def slug(self) -> str:
        return f"{self.owner}/{self.repo}"


def extract_metadata(nix_file: Path) -> Metadata:
    log_info(f"Checking metadata for '{nix_file}'...")
    with pkg_wrapper(nix_file) as wrapper:
        update_type = nix_eval(
            f"let p = import {wrapper}; us = p.passthru.updateScript or null; "
            f'in if us == null then "" else builtins.typeOf us'
        )
        kind: Literal["", "string", "path"] = (
            "string" if update_type == "string" else "path" if update_type == "path" else ""
        )

        owner = repo = ""
        if kind:
            log_info(f"Found custom passthru.updateScript ({kind}) in package")
            homepage = nix_eval(f'(import {wrapper}).meta.homepage or ""')
            m = re.match(r"https://github\.com/([^/]+)/([^/]+)", homepage)
            if m:
                owner, repo = m.group(1), m.group(2)
            else:
                owner = repo = "unknown"
        else:
            if update_type:
                log_info(
                    f"passthru.updateScript has type '{update_type}', falling back to nix-update"
                )
            owner = nix_eval(f"(import {wrapper}).src.owner")
            repo = nix_eval(f"(import {wrapper}).src.repo")
            if not owner or not repo:
                log_error(
                    f"Could not extract owner/repo from '{nix_file}'. "
                    "Make sure that file contains 'owner' and 'repo' attributes.",
                    file=str(nix_file),
                )
                raise typer.Exit(1)

    log_info(f"Found repository: {owner}/{repo}")
    return Metadata(owner=owner, repo=repo, update_script_kind=kind)


def run_path_update_script(nix_file: Path, wrapper: Path) -> None:
    script_path = nix_eval(f"toString (import {wrapper}).pkg.passthru.updateScript")
    if not script_path or not Path(script_path).is_file():
        log_error(f"Could not resolve path updateScript for '{nix_file}'")
        raise typer.Exit(1)
    with contextlib.suppress(OSError):
        os.chmod(script_path, 0o755)
    if run([script_path], env_extra={"UPDATE_FILE": str(nix_file)}).returncode != 0:
        log_error("updateScript failed", file=str(nix_file))
        raise typer.Exit(1)


def run_string_update_script(nix_file: Path, meta: Metadata) -> None:
    log_info("Executing updateScript...")
    print()

    pkg_name = nix_file.stem
    out_link = Path(os.environ.get("TEMP_DIR", "/tmp")) / "update-script-result"
    if out_link.is_symlink() or out_link.exists():
        out_link.unlink()

    with pkg_wrapper(nix_file) as wrapper:
        wrapper.write_text(
            "{ pkgs ? import <nixpkgs> {} }:\n"
            "let\n"
            f"  pkg = pkgs.callPackage {nix_file} {{}};\n"
            f'in pkgs.writeShellScriptBin "{pkg_name}-update-script" '
            "(builtins.readFile pkg.passthru.updateScript)\n"
        )
        try:
            build = run(
                [
                    "nix",
                    "build",
                    "--impure",
                    "--file",
                    wrapper,
                    "--out-link",
                    out_link,
                    "--print-build-logs",
                ]
            )
            if build.returncode != 0:
                log_error(f"Failed to build updateScript for {meta.slug}", file=str(nix_file))
                raise typer.Exit(1)

            bin_dir = out_link / "bin"
            binary = next(
                (p for p in bin_dir.iterdir() if p.is_file() and os.access(p, os.X_OK)),
                None,
            )
            if binary is None:
                log_error(f"No executable found in {bin_dir}")
                raise typer.Exit(1)

            if run([binary], env_extra={"UPDATE_FILE": str(nix_file)}).returncode != 0:
                log_error("updateScript failed")
                raise typer.Exit(1)
        finally:
            if out_link.is_symlink() or out_link.exists():
                with contextlib.suppress(OSError):
                    out_link.unlink()


def run_nix_update(nix_file: Path, wrapper: Path, version: str, meta: Metadata) -> None:
    log_info(f"Executing nix-update with version '{version}'...")
    print()
    r = run(
        [
            "nix-update",
            f"--version={version}",
            "-f",
            wrapper,
            "--override-filename",
            nix_file,
            "pkg",
        ]
    )
    if r.returncode != 0:
        log_error(f"nix-update failed for {meta.slug}", file=str(nix_file))
        raise typer.Exit(1)


def write_pkg_summary(nix_file: Path, meta: Metadata, version: str) -> None:
    parts = [
        f"### {nix_file.stem}\n",
        f"- Repository: `{meta.slug}`\n",
    ]
    if not meta.update_script_kind:
        parts.append(f"- Version: `{version}`\n")
    parts.append(f"- File: `{nix_file}`\n")
    gha_summary("".join(parts))


def update_one(nix_file: Path, version: str = "stable") -> None:
    abs_nix_file = nix_file.resolve()
    with gha_group(f"Package update: {nix_file}"):
        meta = extract_metadata(abs_nix_file)

        log_info(f"Updating '{abs_nix_file}' for {meta.slug}...")
        log_notice(f"Updating {meta.slug}", file=str(abs_nix_file))

        if meta.update_script_kind == "string":
            run_string_update_script(abs_nix_file, meta)
        else:
            with pkg_wrapper(abs_nix_file, rec=True) as wrapper:
                if meta.update_script_kind == "path":
                    run_path_update_script(abs_nix_file, wrapper)
                else:
                    run_nix_update(abs_nix_file, wrapper, version, meta)

        write_pkg_summary(abs_nix_file, meta, version)
        log_notice("Package update completed successfully!")


def is_fetchable_derivation(pkg_path: Path) -> bool:
    expr = (
        f'let p = (with import <nixpkgs> {{}}; callPackage "{pkg_path}" {{}}); '
        f'in if (p.type or "") == "derivation" && p ? src then "1" else ""'
    )
    return nix_eval(expr) == "1"


def build_pkg(pkg_path: Path) -> bool:
    expr = f'with import <nixpkgs> {{}}; (callPackage "{pkg_path}" {{}})'
    return run(["nix", "build", "--impure", "--no-link", "--expr", expr]).returncode == 0


def revert(pkg_dir: Path) -> None:
    run(["git", "checkout", "--", pkg_dir], cwd=REPO_ROOT)


def commit_pkg(pkg_name: str, pkg_dir: Path) -> bool:
    run(["git", "add", pkg_dir], cwd=REPO_ROOT, check=True)
    if run(["git", "diff", "--staged", "--quiet"], cwd=REPO_ROOT).returncode == 0:
        return False
    run(["git", "commit", "-m", f"{pkg_name}: bump"], cwd=REPO_ROOT, check=True)
    return True


@app.command("pkg")
def cmd_pkg(
    nix_file: Path = typer.Argument(
        ...,
        exists=True,
        dir_okay=False,
        readable=True,
        help="Path to a package.nix under pkgs/by-name.",
    ),
    version: str = typer.Option(
        "stable",
        "--version",
        help="Version argument for nix-update (ignored when an updateScript is present).",
    ),
) -> None:
    """Update a single package."""
    update_one(nix_file, version)


@app.command("all")
def cmd_all(
    by_name: Path = typer.Option(
        REPO_ROOT / "pkgs" / "by-name",
        "--by-name",
        help="Root of the by-name package tree.",
    ),
) -> None:
    """Walk pkgs/by-name, update each fetchable derivation, and commit per-package bumps."""
    if not shutil.which("nix") or not shutil.which("git"):
        gha("error", "nix and git must be on PATH")
        raise typer.Exit(1)

    pkg_files = sorted(by_name.rglob("package.nix"))
    updated: list[str] = []

    for nixfile in pkg_files:
        pkg_dir = nixfile.parent
        name = pkg_dir.name

        with gha_group(f"Updating {name}"):
            if not is_fetchable_derivation(nixfile):
                gha("notice", f"Skipping {name} (not a fetchable derivation)", file=str(nixfile))
                continue

            try:
                update_one(nixfile)
            except typer.Exit:
                gha("error", f"Update failed for {name}", file=str(nixfile))
                revert(pkg_dir)
                continue

            if not build_pkg(nixfile):
                gha("error", f"Build failed for {name} after update", file=str(nixfile))
                revert(pkg_dir)
                continue

            if commit_pkg(name, pkg_dir):
                updated.append(f"{name}|{pkg_dir}")
                gha("notice", f"Updated {name} successfully and build verified")

    gha_output("has_changes", "true" if updated else "false")
    if updated:
        gha_summary("### Updated packages\n```\n" + "\n".join(updated) + "\n```\n")
    else:
        gha_summary("### No changes detected\nAll packages are up to date.\n")


if __name__ == "__main__":
    app()

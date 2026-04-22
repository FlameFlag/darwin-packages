default:
    @just --list

# Format everything (yaml, python, nix).
fmt: fmt-yaml fmt-py fmt-nix

# Format .github YAML with yamlfmt.
fmt-yaml:
    yamlfmt .github

# Format Python scripts with ruff (format + lint autofix).
fmt-py:
    ruff format scripts/
    ruff check --fix scripts/

# Format Nix files with nixfmt.
fmt-nix:
    find . -name '*.nix' -not -path './.git/*' -print0 | xargs -0 nixfmt

# Check-mode equivalents (what CI runs).
check: check-yaml check-py check-nix

check-yaml:
    yamlfmt -lint .github

check-py:
    ruff format --check scripts/
    ruff check scripts/

check-nix:
    find . -name '*.nix' -not -path './.git/*' -print0 | xargs -0 nixfmt --check

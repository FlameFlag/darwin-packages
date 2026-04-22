default:
    @just --list

fmt: fmt-yaml fmt-py

fmt-yaml:
    yamlfmt .github

fmt-py:
    ruff format scripts/
    ruff check --fix scripts/

check: check-yaml check-py

check-yaml:
    yamlfmt -lint .github

check-py:
    ruff format --check scripts/
    ruff check scripts/

check-nix:
    find . -name '*.nix' -not -path './.git/*' -print0 | xargs -0 nixfmt --check

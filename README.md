<div align="center">

# darwin-packages

![Platform](https://img.shields.io/badge/platform-macOS-000000?style=flat-square&logo=apple&logoColor=white)
![Nix Flake](https://img.shields.io/badge/nix-flake-5277C3?style=flat-square&logo=nixos&logoColor=white)
![Architecture](https://img.shields.io/badge/arch-aarch64%20%7C%20x86__64-blue?style=flat-square)
![License](https://img.shields.io/github/license/flameflag/darwin-packages?style=flat-square)
![Last Commit](https://img.shields.io/github/last-commit/flameflag/darwin-packages?style=flat-square)
![Stars](https://img.shields.io/github/stars/flameflag/darwin-packages?style=flat-square)

</div>

A minimal nixpkgs-like clone that focuses on providing Darwin-specific packages
built from source, along with any additional Darwin packages that are missing
upstream

> [!NOTE]
> This repo mainly exists for demonstration purposes, showing that a lot of
> macOS GUI software can be built from source, and as a reference for me or
> anyone else who wishes to upstream the build-from-source process for any of
> the packages here into nixpkgs

The layout mirrors nixpkgs' `pkgs/by-name` convention, and the flake exposes
an overlay you can compose into your own `nixpkgs` so the resulting package set
inherits your `config` (e.g. `allowUnfree`) and overlays

## Usage

### Add as a flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darwin-packages.url = "github:flameflag/darwin-packages";
  };
}
```

### Use the overlay (recommended)

```nix
{
  outputs = { self, nixpkgs, darwin-packages, ... }: {
    darwinConfigurations.myHost = nixpkgs.lib.darwinSystem {
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.config.allowUnfree = true;
          nixpkgs.overlays = [ darwin-packages.overlays.default ];

          environment.systemPackages = with pkgs; [ ghostty karabiner-elements ];
        })
      ];
    };
  };
}
```

### Use `legacyPackages`

Note: `legacyPackages` is built from the `nixpkgs` this flake imports with no
`config` applied, so unfree packages will be refused. Prefer `overlays.default`
unless you explicitly want this flake's pinned nixpkgs

```nix
environment.systemPackages = with darwin-packages.legacyPackages.aarch64-darwin; [
  ghostty
  karabiner-elements
];
```

### Cherry-picking a subset

```nix
nixpkgs.overlays = [
  (final: prev: {
    inherit (prev.extend darwin-packages.overlays.default) ghostty;
  })
];
```

## Packages

<!--[[[cog
import subprocess, cog
cog.out("\n" + subprocess.check_output(
    ["python3", "scripts/gen-pkg-table.py"], text=True
) + "\n")
]]]-->

| Package                                                                  | Version   | Description                                                                  |
|--------------------------------------------------------------------------|-----------|------------------------------------------------------------------------------|
| [`alt-tab-macos`](pkgs/by-name/al/alt-tab-macos)                         | `10.12.0` | Windows alt-tab on macOS                                                     |
| [`ghostty`](pkgs/by-name/gh/ghostty)                                     | `1.3.1`   | Fast, native, feature-rich terminal emulator pushing modern features         |
| [`karabiner-elements`](pkgs/by-name/ka/karabiner-elements)               | `16.0.0`  | Powerful utility for keyboard customization on macOS Ventura (13) or later   |
| [`karabiner-elements-vendor`](pkgs/by-name/ka/karabiner-elements-vendor) | `16.0.0`  | Vendored C++ dependencies (asio, spdlog, pqrs/*, ...) for karabiner-elements |
| [`libkrbn`](pkgs/by-name/li/libkrbn)                                     | `16.0.0`  | Karabiner-Elements configuration library (C API over the C++ core)           |
| [`stats`](pkgs/by-name/st/stats)                                         | `2.12.12` | macOS system monitor in your menu bar                                        |

<!--[[[end]]]-->

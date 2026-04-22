/*
  This file extends Nixpkgs with our overlay packages.

  This is similar to how overlays work in nixpkgs, but this is a
  standalone overlay repository.
*/

{
  system ? null,
  stdenv,
  crossSystem ? stdenv.hostPlatform.system,
  config ? { },
  overlays ? [ ],
  crossOverlays ? [ ],
  nixpkgsPath ? <nixpkgs>,
  ...
}@args:

let
  # Import Nixpkgs to get the full package set and lib
  actualSystem = if system != null then system else stdenv.hostPlatform.system;
  nixpkgsPkgs = import nixpkgsPath {
    system = actualSystem;
    inherit
      crossSystem
      config
      overlays
      crossOverlays
      ;
  };

  # Our overlay that adds packages from pkgs/by-name
  ourOverlay = import ./by-name-overlay.nix {
    baseDirectory = ../by-name;
    lib = nixpkgsPkgs.lib;
  };

in
# Apply our overlay to nixpkgs
nixpkgsPkgs.extend ourOverlay

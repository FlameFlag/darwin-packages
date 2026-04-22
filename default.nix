/*
  Default entry point for non-flake usage (nix-build, nix-env, etc.).

  Imports nixpkgs and extends it with our overlay packages.
*/

{
  system ? builtins.currentSystem,
  nixpkgsPath ? <nixpkgs>,
  ...
}:

let
  nixpkgs = import nixpkgsPath { inherit system; };
in
import ./pkgs/top-level/default.nix {
  inherit system nixpkgsPath;
  inherit (nixpkgs) stdenv;
}

# This file turns the pkgs/by-name directory (see its README.md in nixpkgs for
# more info) into an overlay that adds all the defined packages.
# No validity checks are done here,
# instead this file is optimised for performance,
# and validity checks are done by CI on PRs.
#
# This is a close mirror of nixpkgs's pkgs/top-level/by-name-overlay.nix.
# The only deliberate divergence is in the final `self: super:` function:
# because this overlay is applied on top of an existing nixpkgs, a by-name
# package may intentionally override an upstream attribute of the same name.
# See the comment next to that code for details.

# Type: { baseDirectory, lib } -> Overlay
{ baseDirectory, lib, ... }:
let
  inherit (builtins)
    readDir
    ;

  inherit (lib.attrsets)
    mapAttrs
    mapAttrsToList
    mergeAttrsList
    ;

  # Package files for a single shard
  # Type: String -> String -> AttrsOf Path
  namesForShard =
    shard: type:
    if type != "directory" then
      # Ignore all non-directories. Technically only README.md is allowed as a file in the base directory, so we could alternatively:
      # - Assume that README.md is the only file and change the condition to `shard == "README.md"` for a minor performance improvement.
      #   This would however cause very poor error messages if there's other files.
      # - Ensure that README.md is the only file, throwing a better error message if that's not the case.
      #   However this would make for a poor code architecture, because one type of error would have to be duplicated in the validity checks and here.
      # Additionally in either of those alternatives, we would have to duplicate the hardcoding of "README.md"
      { }
    else
      mapAttrs (name: _: baseDirectory + "/${shard}/${name}/package.nix") (
        readDir (baseDirectory + "/${shard}")
      );

  # The attribute set mapping names to the package files defining them
  # This is defined up here in order to allow reuse of the value (it's kind of expensive to compute)
  # if the overlay has to be applied multiple times
  packageFiles = mergeAttrsList (mapAttrsToList namesForShard (readDir baseDirectory));
in
self: super:
{
  # This attribute is necessary to allow CI to ensure that all packages defined in `pkgs/by-name`
  # don't have an overriding definition in `all-packages.nix` with an empty (`{ }`) second `callPackage` argument.
  # It achieves that with an overlay that modifies both `callPackage` and this attribute to signal whether `callPackage` is used
  # and whether it's defined by this file here or `all-packages.nix`.
  # TODO: This can be removed once `pkgs/by-name` can handle custom `callPackage` arguments without `all-packages.nix` (or any other way of achieving the same result).
  # Because at that point the code in ./stage.nix can be changed to not allow definitions in `all-packages.nix` to override ones from `pkgs/by-name` anymore and throw an error if that happens instead.
  _internalCallByNamePackageFile = file: self.callPackage file { };
}
// mapAttrs (
  name: file:
  # Divergence from upstream nixpkgs: this overlay is applied on top of an
  # existing nixpkgs, so a by-name package may intentionally override an
  # upstream attribute of the same name. `self.callPackage` would then
  # infinitely recurse when the package references itself (e.g. via
  # `.overrideAttrs`), so for colliding names we use `super.callPackage` and
  # explicitly pass the original attribute. Fresh names use the normal
  # upstream path so they can see sibling by-name packages through `self`.
  if super ? ${name} then
    super.callPackage file { ${name} = super.${name}; }
  else
    self._internalCallByNamePackageFile file
) packageFiles

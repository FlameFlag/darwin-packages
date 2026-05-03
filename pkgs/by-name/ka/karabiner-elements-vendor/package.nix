{
  lib,
  stdenv,
  fetchFromGitHub,
  cacert,
  cmake,
  git,
  python3,
  nix-update-script,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "karabiner-elements-vendor";
  version = "16.0.0";

  src = fetchFromGitHub {
    owner = "pqrs-org";
    repo = "Karabiner-Elements";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    hash = "sha256-TFSfl28VunnOo2/l7SZuat4lAUuVsDiTzDAovD/+3O4=";
  };

  nativeBuildInputs = [
    cacert
    cmake
    git
    python3
  ];

  # Don't let cmake configure the project root; we only want vendor/
  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    # common.cmake hardcodes CPM_SOURCE_CACHE to ~/.local/cpm-cmake/...
    export HOME="$TMPDIR"

    # Some pqrs submodules reference git@github.com:; rewrite to HTTPS.
    git config --global url."https://github.com/".insteadOf "git@github.com:"

    cd vendor

    # Populate vendor/vendor/{include,src}. CPM clones into its own cache then
    # copy_vendor_package() copies into VENDOR_INCLUDE_DIR.
    rm -rf vendor
    cmake -S . -B build
    cmake --build build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r vendor "$out/vendor"
    runHook postInstall
  '';

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = "sha256-Ag6JU9uRWBeBizMiJjHXcjnBdpvt+K7cZ2YojQjOX6I=";

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Vendored C++ dependencies (asio, spdlog, pqrs/*, ...) for karabiner-elements";
    homepage = "https://github.com/pqrs-org/Karabiner-Elements";
    license = lib.licenses.unlicense;
    maintainers = with lib.maintainers; [ auscyber ];
    platforms = lib.platforms.darwin;
  };
})

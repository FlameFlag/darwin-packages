{
  lib,
  fetchFromGitHub,
  python3,
  swiftPackages,
  karabiner-elements-vendor,
}:

# Built from the Karabiner-Elements source tree but kept as its own package so
# that other tooling can theoretically `-lkrbn` against it without pulling in
# the full Karabiner installation
swiftPackages.stdenv.mkDerivation (finalAttrs: {
  pname = "libkrbn";
  inherit (karabiner-elements-vendor) version;

  src = fetchFromGitHub {
    owner = "pqrs-org";
    repo = "Karabiner-Elements";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    inherit (karabiner-elements-vendor.src) hash;
  };

  nativeBuildInputs = [
    python3
    swiftPackages.swift
  ];

  dontConfigure = true;

  postPatch = ''
    cp -r ${karabiner-elements-vendor}/vendor vendor/vendor
    chmod -R u+w vendor/vendor
    python3 scripts/update_version.py
  '';

  buildPhase = ''
    runHook preBuild

    buildDir="$PWD/build"
    mkdir -p "$buildDir"

    cxxflags=(
      -std=c++20 -O2 -Wall
      -mmacosx-version-min=13.0
      -I src/share
      -I src/lib/libkrbn/include
      -isystem vendor/Karabiner-DriverKit-VirtualHIDDevice/include
      -isystem vendor/vendor/include
    )

    objs=()

    for src in src/lib/libkrbn/src/*.cpp; do
      obj="$buildDir/$(basename "$src" .cpp).o"
      c++ "''${cxxflags[@]}" -c "$src" -o "$obj"
      objs+=("$obj")
    done

    # The pqrs frontmost_application_monitor swift @_cdecl glue is a libkrbn
    # source per the upstream project.yml. Compile it and bake it into the .a.
    swiftc -O -parse-as-library \
      -module-name PQRSOSXFrontmostApplicationMonitorImpl \
      -import-objc-header vendor/vendor/include/pqrs/osx/frontmost_application_monitor/impl/Bridging-Header.h \
      -emit-object \
      vendor/vendor/src/pqrs/osx/frontmost_application_monitor/PQRSOSXFrontmostApplicationMonitorImpl.swift \
      -o "$buildDir/PQRSOSXFrontmostApplicationMonitorImpl.o"
    objs+=("$buildDir/PQRSOSXFrontmostApplicationMonitorImpl.o")

    ar rcs "$buildDir/libkrbn.a" "''${objs[@]}"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 "$buildDir/libkrbn.a" "$out/lib/libkrbn.a"

    mkdir -p "$out/include"
    cp -r src/lib/libkrbn/include/libkrbn "$out/include/libkrbn"
    install -Dm644 src/share/karabiner_version.h "$out/include/karabiner_version.h"

    runHook postInstall
  '';

  meta = {
    description = "Karabiner-Elements configuration library (C API over the C++ core)";
    homepage = "https://github.com/pqrs-org/Karabiner-Elements";
    license = lib.licenses.unlicense;
    maintainers = with lib.maintainers; [ auscyber ];
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
})

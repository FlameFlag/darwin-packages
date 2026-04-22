{
  lib,
  fetchFromGitHub,
  python3,
  swiftPackages,
  symlinkJoin,
  karabiner-elements-vendor,
  libkrbn,
  nix-update-script,
  # Our name collides with an upstream nixpkgs attribute; the by-name overlay
  # in this repo passes the upstream package through under this name to avoid
  # infinite recursion when it's referenced via `self`. We don't use it.
  karabiner-elements ? null,
}:
let
  inherit (karabiner-elements-vendor) version;
  inherit (lib) escapeShellArgs concatMap mapAttrs attrValues;

  src = fetchFromGitHub {
    owner = "pqrs-org";
    repo = "Karabiner-Elements";
    tag = "v${version}";
    fetchSubmodules = true;
    inherit (karabiner-elements-vendor.src) hash;
  };

  # Nix-side description of the shared compile environment. These lists are
  # emitted into each binary's buildPhase via `escapeShellArgs`, so adding or
  # removing a flag/framework/include is a pure data edit.
  baseCxxFlags = [
    "-std=c++20"
    "-O2"
    "-Wall"
    "-mmacosx-version-min=13.0"
    "-I"
    "src/share"
    "-isystem"
    "vendor/Karabiner-DriverKit-VirtualHIDDevice/include"
    "-isystem"
    "vendor/vendor/include"
  ];

  frameworks = concatMap (f: [
    "-framework"
    f
  ]) [
    "AppKit"
    "Carbon"
    "CoreFoundation"
    "CoreGraphics"
    "CoreServices"
    "Foundation"
    "IOKit"
    "Security"
  ];

  # pqrs/osx swift @_cdecl glue modules that live under vendor/vendor/src/.
  # The actual .swift files are only present after karabiner-elements-vendor
  # has built, so the per-file loop still runs in bash — but the module set
  # is declared here.
  swiftGlueModules = [
    "process_info"
    "workspace"
  ];
  swiftGlueRoots = map (m: "vendor/vendor/src/pqrs/osx/${m}") swiftGlueModules;

  duktapeIncludeDirs = [
    "vendor/duktape-2.7.0/src"
    "vendor/duktape-2.7.0/extras/console"
    "vendor/duktape-2.7.0/extras/module-node"
  ];
  duktapeSources = [
    "vendor/duktape-2.7.0/src/duktape.c"
    "vendor/duktape-2.7.0/extras/console/duk_console.c"
    "vendor/duktape-2.7.0/extras/module-node/duk_module_node.c"
  ];
  duktapeIncludeFlags = concatMap (d: [
    "-I"
    d
  ]) duktapeIncludeDirs;

  # Single generator. Each binary is fully described by its spec; buildPhase
  # is assembled uniformly from that data.
  mkBinary =
    {
      pname,
      mainSource,
      extraIncludes ? [ ],
      extraCxxFlags ? [ ],
      extraCSources ? [ ], # compiled with `cc` into $buildDir/extra_*.o
      extraCFlags ? [ ],
    }:
    let
      includeFlags = concatMap (d: [
        "-I"
        d
      ]) extraIncludes;
      cxxflagsShell = escapeShellArgs (baseCxxFlags ++ includeFlags ++ extraCxxFlags);
      cflagsShell = escapeShellArgs (extraCFlags ++ includeFlags);
      frameworksShell = escapeShellArgs frameworks;
      swiftRootsShell = escapeShellArgs swiftGlueRoots;
      extraCSourcesShell = escapeShellArgs extraCSources;
    in
    swiftPackages.stdenv.mkDerivation {
      inherit pname version src;

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

      env.LIBKRBN = "${libkrbn}";

      buildPhase = ''
        runHook preBuild

        buildDir="$PWD/build"
        mkdir -p "$buildDir"

        # -I "$LIBKRBN/include" appended in bash because it needs $LIBKRBN.
        cxxflags=( ${cxxflagsShell} -I "$LIBKRBN/include" )
        frameworks=( ${frameworksShell} )

        # Swift @_cdecl glue: compile every .swift under each module root.
        swiftObjs=()
        for src in $(find ${swiftRootsShell} -name '*.swift' 2>/dev/null); do
          base=$(basename "$src" .swift)
          modName=$(basename "$(dirname "$src")")
          bridge="vendor/vendor/include/pqrs/osx/$modName/impl/Bridging-Header.h"
          obj="$buildDir/swift_''${base}.o"
          swiftc -O -parse-as-library -module-name "$base" \
            -import-objc-header "$bridge" \
            -emit-object "$src" -o "$obj"
          swiftObjs+=("$obj")
        done

        # Spec-provided extra C sources (duktape for the CLI, empty for daemons).
        extraObjs=()
        for src in ${extraCSourcesShell}; do
          obj="$buildDir/extra_$(basename "$src" .c).o"
          cc ${cflagsShell} -c "$src" -o "$obj"
          extraObjs+=("$obj")
        done

        c++ "''${cxxflags[@]}" -fobjc-arc \
          -c ${lib.escapeShellArg mainSource} \
          -o "$buildDir/main.o"

        # Link via swiftc so the swift runtime is wired up automatically.
        swiftc -O \
          "$buildDir/main.o" \
          "''${extraObjs[@]}" \
          "''${swiftObjs[@]}" \
          "$LIBKRBN/lib/libkrbn.a" \
          -lc++ \
          "''${frameworks[@]}" \
          -o "$buildDir/${pname}"

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 "$PWD/build/${pname}" "$out/bin/${pname}"
        runHook postInstall
      '';

      meta = {
        homepage = "https://karabiner-elements.pqrs.org/";
        license = lib.licenses.unlicense;
        platforms = lib.platforms.darwin;
        sourceProvenance = with lib.sourceTypes; [ fromSource ];
      };
    };

  # Data-driven binary table. Add a new binary by adding an entry here; the
  # future src/apps/ GUI bundles will slot in the same way.
  mkDaemonSpec = sourceDir: {
    mainSource = "src/core/${sourceDir}/src/main.cpp";
    extraIncludes = [ "src/core/${sourceDir}/include" ];
  };

  binarySpecs = {
    karabiner_session_monitor = mkDaemonSpec "session_monitor";
    karabiner_console_user_server = mkDaemonSpec "console_user_server";
    "Karabiner-Core-Service" = mkDaemonSpec "CoreService";

    karabiner_cli = {
      mainSource = "src/bin/cli/src/main.cpp";
      extraIncludes = duktapeIncludeDirs;
      extraCSources = duktapeSources;
      extraCFlags = [
        "-O2"
        "-Wno-deprecated-declarations"
        "-Wno-unused-but-set-variable"
      ];
    };
  };

  binaries = mapAttrs (pname: spec: mkBinary (spec // { inherit pname; })) binarySpecs;
in
symlinkJoin {
  name = "karabiner-elements-${version}";
  inherit version;
  pname = "karabiner-elements";

  paths = attrValues binaries;

  passthru = {
    inherit (binaries) karabiner_cli;
    inherit binaries;
    updateScript = nix-update-script { };
  };

  meta = {
    changelog = "https://github.com/pqrs-org/Karabiner-Elements/releases/tag/v${version}";
    description = "Powerful utility for keyboard customization on macOS Ventura (13) or later";
    homepage = "https://karabiner-elements.pqrs.org/";
    license = lib.licenses.unlicense;
    maintainers = with lib.maintainers; [ auscyber ];
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
}

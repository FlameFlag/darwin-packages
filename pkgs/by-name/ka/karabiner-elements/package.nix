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
  inherit (lib)
    concatMap
    mapAttrs
    attrValues
    toShellVars
    ;

  prefixEach =
    flag:
    concatMap (x: [
      flag
      x
    ]);

  src = fetchFromGitHub {
    owner = "pqrs-org";
    repo = "Karabiner-Elements";
    tag = "v${version}";
    fetchSubmodules = true;
    inherit (karabiner-elements-vendor.src) hash;
  };

  # Nix-side description of the shared compile environment. These lists are
  # emitted into each binary's buildPhase via `toShellVars`, so adding or
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

  frameworks = prefixEach "-framework" [
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
  # Files are only materialized after karabiner-elements-vendor builds, so the
  # per-file expansion still happens at build time via a bash glob, but each
  # module gets its own block so the bridging-header path comes from Nix.
  swiftGlueModules = [
    "process_info"
    "workspace"
  ];

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
  duktapeIncludeFlags = prefixEach "-I" duktapeIncludeDirs;

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
      includeFlags = prefixEach "-I" extraIncludes;
      shellVars = toShellVars {
        cxxflags = baseCxxFlags ++ includeFlags ++ extraCxxFlags;
        cflags = extraCFlags ++ includeFlags;
        frameworks = frameworks;
      };

      # Compile one C source at a fixed path into $buildDir/extra_<base>.o.
      compileExtraC = src: ''
        cc "''${cflags[@]}" -c ${lib.escapeShellArg src} \
          -o "$buildDir/extra_$(basename ${lib.escapeShellArg src} .c).o"
        extraObjs+=("$buildDir/extra_$(basename ${lib.escapeShellArg src} .c).o")
      '';

      # Compile every .swift in one pqrs/osx glue module with its bridging header.
      compileSwiftGlue = mod: ''
        shopt -s nullglob
        for src in vendor/vendor/src/pqrs/osx/${mod}/*.swift; do
          base=$(basename "$src" .swift)
          obj="$buildDir/swift_''${base}.o"
          swiftc -O -parse-as-library -module-name "$base" \
            -import-objc-header vendor/vendor/include/pqrs/osx/${mod}/impl/Bridging-Header.h \
            -emit-object "$src" -o "$obj"
          swiftObjs+=("$obj")
        done
        shopt -u nullglob
      '';
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

        ${shellVars}
        # -I "$LIBKRBN/include" appended in bash because it needs $LIBKRBN.
        cxxflags+=( -I "$LIBKRBN/include" )

        # Swift @_cdecl glue: one block per module, bridging-header from Nix.
        swiftObjs=()
        ${lib.concatMapStrings compileSwiftGlue swiftGlueModules}

        # Spec-provided extra C sources (duktape for the CLI, empty for daemons).
        extraObjs=()
        ${lib.concatMapStrings compileExtraC extraCSources}

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

{
  lib,
  stdenv,
  swiftPackages,
  actool,
  apple-sdk,
  apple-sdk_15,
  blueprint-compiler,
  bzip2,
  callPackage,
  darwin,
  fetchFromGitHub,
  fontconfig,
  freetype,
  glib,
  glslang,
  gtk4-layer-shell,
  harfbuzz,
  ibtool,
  libadwaita,
  libGL,
  libx11,
  libxml2,
  makeWrapper,
  ncurses,
  nixosTests,
  oniguruma,
  pandoc,
  pkg-config,
  removeReferencesTo,
  versionCheckHook,
  wrapGAppsHook4,
  writeShellApplication,
  zig_0_15,

  # Upstream recommends a non-default level
  # https://github.com/ghostty-org/ghostty/blob/4b4d4062dfed7b37424c7210d1230242c709e990/PACKAGING.md#build-options
  optimizeLevel ? "ReleaseFast",
}:
let
  isDarwin = stdenv.hostPlatform.isDarwin;

  # On macOS, use Swift-capable stdenv
  effectiveStdenv = if isDarwin then swiftPackages.stdenv else stdenv;
  swift = swiftPackages.swift;

  # SDK 14.4 path for Swift compilation (Swift 5.10 is incompatible with SDK 15.5)
  swiftSdkPath = apple-sdk;

  # Patched ibtool: upstream 1.1.4 incorrectly class-swaps NSWindowTemplate
  # to NSClassSwapper when a <window> has customClass+customModule, losing
  # the unmangled IBClassReference. Ghostty's Terminal.xib and
  # QuickTerminal.xib hit this.
  ibtool' = ibtool.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/0003-ibtool-nswindowtemplate-no-class-swap.patch
    ];
  });

  toPlist = lib.generators.toPlist { escape = true; };

  mkFrameworkPlist =
    { name, identifier }:
    toPlist {
      CFBundleExecutable = name;
      CFBundleIdentifier = identifier;
      CFBundleInfoDictionaryVersion = "6.0";
      CFBundleName = name;
      CFBundlePackageType = "FMWK";
      CFBundleVersion = "1";
    };

  mkPluginPlist =
    {
      name,
      identifier,
      principalClass,
    }:
    toPlist {
      CFBundleExecutable = name;
      CFBundleIdentifier = identifier;
      CFBundleInfoDictionaryVersion = "6.0";
      CFBundleName = name;
      CFBundlePackageType = "BNDL";
      CFBundleVersion = "1";
      NSPrincipalClass = principalClass;
    };

  # Assemble a macOS .app bundle from its components. Emits shell that uses
  # an `$app` variable (set here) for subsequent phase code. Every path-valued
  # argument is a shell expression, so callers can reference build-time vars
  # like "$buildDir/ghostty". Nix store paths work too via ${./foo} coercion.
  mkAppBundle =
    {
      name, # app bundle name (becomes <name>.app)
      executable ? name, # binary name inside Contents/MacOS (often lowercase)
      destDir,
      binary,
      plist,
      frameworks ? [ ], # [{ name, identifier, dylib }]
      plugins ? [ ], # [{ name, identifier, principalClass, binary }]
      xibSourceDir ? null, # source dir to find *.xib files; compiled via ibtool
      sdef ? null, # path to .sdef file
      assetCatalog ? null, # path to .xcassets directory
      extraResources ? [ ], # paths (files or dirs) copied into Contents/Resources
      minimumDeploymentTarget ? "13.0",
    }:
    ''
      nixLog "assembling ${name}.app"
      app="${destDir}/${name}.app"
      mkdir -p "$app/Contents/"{MacOS,Resources,Frameworks}
      cp "${binary}" "$app/Contents/MacOS/${executable}"

      ${lib.concatMapStrings (fw: ''
        nixLog "installing framework: ${fw.name}"
        mkdir -p "$app/Contents/Frameworks/${fw.name}.framework/Resources"
        cp "${fw.dylib}" "$app/Contents/Frameworks/${fw.name}.framework/${fw.name}"
        printf '%s' ${
          lib.escapeShellArg (mkFrameworkPlist {
            inherit (fw) name identifier;
          })
        } \
          > "$app/Contents/Frameworks/${fw.name}.framework/Resources/Info.plist"
      '') frameworks}

      ${lib.concatMapStrings (pl: ''
        nixLog "installing plugin: ${pl.name}"
        mkdir -p "$app/Contents/PlugIns/${pl.name}.plugin/Contents/MacOS"
        cp "${pl.binary}" "$app/Contents/PlugIns/${pl.name}.plugin/Contents/MacOS/${pl.name}"
        printf '%s' ${
          lib.escapeShellArg (mkPluginPlist {
            inherit (pl) name identifier principalClass;
          })
        } > "$app/Contents/PlugIns/${pl.name}.plugin/Contents/Info.plist"
      '') plugins}

      ${lib.optionalString (xibSourceDir != null) ''
        nixLog "compiling XIBs from ${xibSourceDir}"
        while IFS= read -r -d "" xib; do
          name=$(basename "$xib" .xib)
          TZ=Etc/UTC LANG=C LC_ALL=C \
            ibtool --compile "$app/Contents/Resources/$name.nib" "$xib"
        done < <(find ${xibSourceDir} -name '*.xib' -print0)
      ''}

      ${lib.optionalString (sdef != null) ''
        cp ${sdef} "$app/Contents/Resources/"
      ''}

      ${lib.optionalString (assetCatalog != null) ''
        nixLog "compiling asset catalog"
        actool --compile "$app/Contents/Resources" \
          --platform macosx --minimum-deployment-target ${minimumDeploymentTarget} \
          ${assetCatalog}
      ''}

      ${lib.concatMapStrings (res: ''
        cp -r ${res} "$app/Contents/Resources/"
      '') extraResources}

      printf '%s' ${lib.escapeShellArg plist} > "$app/Contents/Info.plist"
    '';

  # Swift shim: the nixpkgs swiftc wrapper adds -external-plugin-path flags
  # pointing to swift-plugin-server, which doesn't exist in our SDK and
  # crashes the frontend in the Nix sandbox. Install a frontend shim that
  # strips those flags and a swiftc copy that calls the shim. Emits a
  # shell variable `nixSwiftc` pointing to the patched driver.
  swiftFrontendShim = writeShellApplication {
    name = "swift-frontend";
    runtimeInputs = [ ];
    text = ''
      # Strip -external-plugin-path flags (swift-plugin-server is absent in our SDK
      # and makes the frontend crash in the Nix sandbox). Delegates to the raw
      # frontend whose path is passed via GHOSTTY_RAW_SWIFT_FRONTEND.
      filtered=()
      skip_next=0
      plugin_count=0
      for arg in "$@"; do
        if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
        if [ "$arg" = "-external-plugin-path" ]; then skip_next=1; plugin_count=$((plugin_count+1)); continue; fi
        filtered+=("$arg")
      done
      echo "swift-frontend-shim: filtered $plugin_count plugin paths from $# args, passing ''${#filtered[@]} args" >&2
      exec "$GHOSTTY_RAW_SWIFT_FRONTEND" "''${filtered[@]}"
    '';
  };

  swiftShimSetup = ''
    rawFrontend=$(sed -n 's/^prog=//p' ${swift}/bin/swift-frontend)
    export GHOSTTY_RAW_SWIFT_FRONTEND="$rawFrontend"
    install -D -m 755 ${lib.getExe swiftFrontendShim} .nix-swift-shim/swift-frontend
    install -m 755 ${swift}/bin/swiftc .nix-swift-shim/swiftc
    sed -i "s|SWIFT_DRIVER_SWIFT_FRONTEND_EXEC=\"$rawFrontend\"|SWIFT_DRIVER_SWIFT_FRONTEND_EXEC=\"$PWD/.nix-swift-shim/swift-frontend\"|g" .nix-swift-shim/swiftc
    nixSwiftc="$PWD/.nix-swift-shim/swiftc"
  '';

  # Plain ObjC helpers linked into the main executable (single .m files
  # under macos/Sources/Helpers, no headers of their own).
  objcHelpers = [
    "ObjCExceptionCatcher"
    "VibrantLayer"
  ];

  # Patterns excluded when collecting Swift sources for the main module.
  swiftSourceExcludes = [
    "*/iOS/*"
    "*/Tests/*"
    "*/GhosttyUITests/*"
    "*/App Intents/*"
  ];

  # zig-out/share/<src> -> Contents/Resources/<dest>. Empty dest flattens into
  # Resources root (ghostty/* goes alongside sdef/nibs).
  resourceShares = [
    {
      src = "ghostty";
      dest = "";
    }
    {
      src = "man";
      dest = "man";
    }
    {
      src = "terminfo";
      dest = "terminfo";
    }
  ];

  # Split outputs: prefer the copy inside the app bundle (already filtered by
  # mkAppBundle); fall back to the zig-out location if the bundle didn't land
  # it (cross-build or disabled feature).
  splitOutputs = [
    {
      output = "terminfo";
      dest = "share/terminfo";
      candidates = [
        "$app/Contents/Resources/terminfo"
        "$zigOut/share/terminfo"
      ];
    }
    {
      output = "shell_integration";
      dest = "shell-integration";
      candidates = [
        "$app/Contents/Resources/shell-integration"
        "$zigOut/share/ghostty/shell-integration"
      ];
    }
  ];

  # Build a stub Swift framework dylib (a single source file compiled via
  # swift-frontend, then linked via clang). The driver (swiftc) crashes in
  # the Nix sandbox, but single-file frontend invocations work. Requires
  # the bash `commonLinkFlags` array to be in scope.
  mkSwiftStubFramework =
    {
      name,
      source, # nix path to .swift file
      frameworks ? [
        "Foundation"
        "AppKit"
      ],
    }:
    ''
      nixLog "building ${name} stub framework"
      swift-frontend -c -parse-as-library \
        -O -sdk "$SDKROOT" -target arm64-apple-macosx13.0 \
        -module-name ${name} -module-link-name ${name} \
        -emit-module-path "$buildDir/${name}.swiftmodule" \
        -emit-module-doc-path "$buildDir/${name}.swiftdoc" \
        ${source} \
        -o "$buildDir/${name}Stub.o"

      clang -dynamiclib -o "$buildDir/lib${name}.dylib" \
        "$buildDir/${name}Stub.o" \
        -install_name "@rpath/${name}.framework/${name}" \
        "''${commonLinkFlags[@]}" \
        -L "$SDKROOT/usr/lib/swift" -L ${swift}/lib/swift/macosx -lswiftCore \
        ${lib.concatMapStringsSep " " (f: "-framework ${f}") frameworks}
    '';

  # Link a Swift+ObjC binary (executable or dylib) against the Ghostty
  # object set. Requires the bash arrays `ghosttyObjs`, `commonLinkFlags`,
  # and `swiftRuntimeFlags` to be in scope.
  mkSwiftLink =
    {
      output,
      kind ? "exe", # "exe" or "dylib"
      frameworks ? [ ],
      libs ? [ ], # extra -l flags (e.g. swiftIOKit)
      extraArgs ? [ ], # raw trailing args
    }:
    let
      kindFlag = lib.optionalString (kind == "dylib") "-dynamiclib ";
      frameworkArgs = lib.concatMapStringsSep " " (f: "-framework ${f}") frameworks;
      libArgs = lib.concatMapStringsSep " " (l: "-l${l}") libs;
      extras = lib.concatStringsSep " " extraArgs;
    in
    ''
      clang ${kindFlag}-o "${output}" \
        "''${ghosttyObjs[@]}" \
        "''${commonLinkFlags[@]}" "''${swiftRuntimeFlags[@]}" \
        ${libArgs} \
        ${frameworkArgs} \
        ${extras}
    '';
in
effectiveStdenv.mkDerivation (finalAttrs: {
  pname = "ghostty";
  version = "1.3.1";

  outputs = [
    "out"
    "shell_integration"
    "terminfo"
    "vim"
  ]
  ++ lib.optionals (!isDarwin) [
    "man"
  ];

  src = fetchFromGitHub {
    owner = "ghostty-org";
    repo = "ghostty";
    tag = "v${finalAttrs.version}";
    hash = "sha256-+ddMmUe9Jjkun4qqW8XFXVgwVZdVHsGWcQzndgIlBjQ=";
  };

  deps = callPackage ./deps.nix {
    name = "${finalAttrs.pname}-cache-${finalAttrs.version}";
  };

  strictDeps = true;

  nativeBuildInputs = [
    ncurses
    pandoc
    pkg-config
    removeReferencesTo
    zig_0_15
  ]
  ++ lib.optionals (!isDarwin) [
    # GTK frontend (Linux only)
    glib
    wrapGAppsHook4
    blueprint-compiler
    libxml2
  ]
  ++ lib.optionals isDarwin [
    swift
    actool
    ibtool'
    apple-sdk # SDK 14.4 for Swift compilation (Swift 5.10 is incompatible with SDK 15.5)
    darwin.cctools # for libtool (used by GhosttyLib to create fat archives)
    darwin.autoSignDarwinBinariesHook
    makeWrapper
  ];

  buildInputs =
    lib.optionals isDarwin [
      apple-sdk_15
    ]
    ++ lib.optionals (!isDarwin) [
      oniguruma

      # GTK frontend
      libadwaita
      libx11
      gtk4-layer-shell

      # OpenGL renderer
      glslang
      libGL

      # Font backend
      bzip2
      fontconfig
      freetype
      harfbuzz
    ];

  # macOS-only source patches. See patches/ directory for details:
  # - 0001-zig-darwin-build.patch: xcframework guards + install internal lib on Darwin
  # - 0002-swift-5-10-compat.patch: Swift 5.10 / SDK 14.4 source compatibility fixes
  patches = lib.optionals isDarwin [
    ./patches/0001-zig-darwin-build.patch
    ./patches/0002-swift-5-10-compat.patch
  ];

  postPatch = lib.optionalString isDarwin ''
    # Use pre-built Metal shaders and a stubbed apple-sdk build.zig that
    # reads SDKROOT instead of calling xcrun (see preBuild).
    # SharedDeps.zig is patched to consume Ghostty.metallib via 0001-zig-darwin-build.patch.
    install -m 644 ${./files/apple-sdk-build.zig} pkg/apple-sdk/build.zig
    cp ${./Ghostty.metallib} Ghostty.metallib

    # xcrun/xcode-select shims for cached deps (zig_objc, MetallibStep) that
    # shell out to these tools. The shims return SDKROOT from the environment.
    install -D -m 755 ${./files/xcrun} .nix-xcrun-shim/xcrun
    install -D -m 755 ${./files/xcode-select} .nix-xcrun-shim/xcode-select
  '';

  # On macOS, override the zig build to use a local copy of the dep cache.
  # Zig's build system uses relative paths between the dep cache and build
  # executables. When the cache is in /nix/store and the build is in a temp
  # dir, the relative path traversal fails in the macOS sandbox.
  dontUseZigBuild = isDarwin;
  dontUseZigInstall = isDarwin;

  preBuild = lib.optionalString isDarwin ''
    export PATH="$PWD/.nix-xcrun-shim:$PATH"
    # Save the Nix SDK path for our patched apple-sdk/build.zig
    export NIX_APPLE_SDK_PATH="$SDKROOT"
  '';

  buildPhase = lib.optionalString isDarwin ''
    runHook preBuild

    # Copy dep cache locally so Zig's relative paths work in the sandbox
    local_deps="$PWD/.nix-zig-deps"
    cp -rL "${finalAttrs.deps}" "$local_deps"
    chmod -R u+w "$local_deps"

    local buildCores="$NIX_BUILD_CORES"
    TERM=dumb zig build \
      "-j$buildCores" \
      --system "$local_deps" \
      -Dversion-string=${finalAttrs.version} \
      -Dcpu=baseline \
      -Doptimize=${optimizeLevel} \
      -Dapp-runtime=none \
      -Demit-xcframework=false \
      -Demit-macos-app=false \
      --verbose

    runHook postBuild
  '';

  dontSetZigDefaultFlags = true;

  zigCheckFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dversion-string=${finalAttrs.version}"
    "-Dcpu=baseline"
  ]
  ++ lib.optionals (!isDarwin) (
    lib.mapAttrsToList (name: package: "-fsys=${name} --search-prefix ${lib.getLib package}") {
      inherit glslang;
    }
  );

  # Only specify the optimization level for the actual build.
  # Tests do not work on ReleaseFast as they rely on triggering
  # specific integrity violations within the internal data structures.
  zigBuildFlags =
    finalAttrs.zigCheckFlags
    ++ [
      "-Doptimize=${optimizeLevel}"
    ]
    ++ lib.optionals isDarwin [
      # On macOS, disable xcframework and macOS app targets since
      # we build the Swift GUI separately below without xcodebuild.
      "-Dapp-runtime=none"
      "-Demit-xcframework=false"
      "-Demit-macos-app=false"
    ];

  doCheck = !isDarwin;

  # On macOS, after the Zig build produces libghostty.a, compile the Swift
  # GUI and link the app binary + DockTilePlugin.
  postBuild = lib.optionalString isDarwin ''
    buildDir="$PWD/build"
    zigOut="$PWD/zig-out"
    mkdir -p "$buildDir" "$buildDir/swift-objs"

    ghosttyLib="$zigOut/lib/libghostty.a"
    if [ ! -f "$ghosttyLib" ]; then
      nixLog "ERROR: libghostty.a not found in zig-out/lib"
      find "$zigOut" -type f \( -name '*.a' -o -name '*.dylib' \) | head -20
      exit 1
    fi

    # Switch to SDK 14.4 for Swift compilation. The Zig build needs SDK 15.5
    # for newer CoreVideo symbols, but Swift 5.10 can't parse SDK 15.5's
    # .swiftinterface files (Swift 6 typed throws) or use its module maps
    # (incompatible _stddef).
    export DEVELOPER_DIR="${swiftSdkPath}"
    export DEVELOPER_DIR_arm64_apple_darwin="${swiftSdkPath}"
    export SDKROOT="${swiftSdkPath}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

    ${swiftShimSetup}

    # Common Swift compile flags
    swiftFlags=(
      -O -enable-bare-slash-regex
      -sdk "$SDKROOT"
      -I "$SDKROOT/usr/lib/swift"
      -Xfrontend -solver-expression-time-threshold=600
      -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.0
    )

    # Shared clang link flags: target + sysroot + platform version
    commonLinkFlags=(
      -target arm64-apple-macosx13.0
      -isysroot "$SDKROOT"
      -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.0
    )

    # Swift runtime library flags. SDK path FIRST so the linker uses the
    # .tbd stubs (which reference /usr/lib/swift at runtime via the dyld
    # shared cache). Nix-store dylibs crash at runtime on newer macOS due
    # to shared cache incompatibility.
    swiftRuntimeFlags=(
      -lstdc++
      -L "$SDKROOT/usr/lib/swift"
      -L ${swift}/lib/swift/macosx
      -lswiftCore -lswift_Concurrency -lswift_StringProcessing -lswiftObservation
      -lswiftFoundation -lswiftAppKit -lswiftCoreFoundation
      -lswiftCoreGraphics -lswiftDarwin -lswiftDispatch -lswiftObjectiveC
      -Xlinker -rpath -Xlinker "${swift}/lib/swift/macosx"
    )

    ${mkSwiftStubFramework {
      name = "Sparkle";
      source = ./stubs/SparkleStub.swift;
    }}

    # ObjC helpers (single .m files, compiled per-name)
    nixLog "compiling ObjC helpers"
    for name in ${lib.escapeShellArgs objcHelpers}; do
      clang -fobjc-arc -O2 -I macos/Sources/Helpers \
        -framework AppKit -framework Foundation \
        -c "macos/Sources/Helpers/$name.m" -o "$buildDir/$name.o"
    done

    # Collect Ghostty Swift sources
    swiftFiles=()
    while IFS= read -r -d "" f; do swiftFiles+=("$f"); done < <(
      find macos/Sources -name '*.swift' \
        ${lib.concatMapStringsSep " " (p: "! -path '${p}'") swiftSourceExcludes} \
        ! -name '*_UIKit.swift' \
        -print0
    )

    # Compile Swift to .o files (we link manually below). The swiftc driver
    # crashes during its own link phase in the Nix sandbox, so we use an
    # output-file-map to collect per-source objects.
    nixLog "compiling Ghostty macOS app (''${#swiftFiles[@]} swift files)"
    {
      printf '{\n'
      for src in "''${swiftFiles[@]}"; do
        name=$(basename "$src" .swift)
        printf '  "%s": {"object": "%s/swift-objs/%s.o"},\n' "$src" "$buildDir" "$name"
      done
      printf '  "": {"swift-dependencies": "%s/swift-objs/Ghostty-master.swiftdeps"}\n}\n' "$buildDir"
    } > "$buildDir/output-file-map.json"

    "$nixSwiftc" -j8 "''${swiftFlags[@]}" \
      -module-name Ghostty \
      -import-objc-header macos/Sources/App/macOS/ghostty-bridging-header.h \
      -I "$buildDir" -I include -I macos/Sources/Helpers \
      -Xcc -I -Xcc macos/Sources/Helpers \
      -c -output-file-map "$buildDir/output-file-map.json" \
      "''${swiftFiles[@]}" \
      || nixLog "swiftc -c exited non-zero (expected: driver crash after compilation)"

    # Collect produced object files (for both the executable and DockTilePlugin)
    swiftObjFiles=()
    while IFS= read -r -d "" f; do swiftObjFiles+=("$f"); done \
      < <(find "$buildDir/swift-objs" -name '*.o' -print0)
    nixLog "produced ''${#swiftObjFiles[@]} object files"

    # Shared object set + Sparkle for the exe and the plugin
    ghosttyObjs=(
      "''${swiftObjFiles[@]}"
      ${lib.concatMapStringsSep " " (n: ''"$buildDir/${n}.o"'') objcHelpers}
      "$ghosttyLib"
      -L "$buildDir" -lSparkle
    )

    nixLog "linking Ghostty executable"
    ${mkSwiftLink {
      output = "$buildDir/ghostty";
      libs = [
        "swiftIOKit"
        "swiftQuartzCore"
        "swiftUniformTypeIdentifiers"
        "swiftXPC"
      ];
      frameworks = [
        "SwiftUI"
        "Combine"
        "AppKit"
        "Cocoa"
        "Carbon"
        "CoreGraphics"
        "CoreText"
        "Foundation"
        "IOKit"
        "Metal"
        "MetalKit"
        "QuartzCore"
        "UniformTypeIdentifiers"
        "UserNotifications"
      ];
      extraArgs = [ ''-Xlinker -rpath -Xlinker "@executable_path/../Frameworks"'' ];
    }}

    # DockTilePlugin references types from the full Ghostty module, so we
    # link all of the Swift object files into it as a dylib.
    nixLog "linking DockTilePlugin"
    ${mkSwiftLink {
      output = "$buildDir/DockTilePlugin";
      kind = "dylib";
      frameworks = [
        "AppKit"
        "Foundation"
        "SwiftUI"
      ];
      extraArgs = [ ''-install_name "@rpath/DockTilePlugin.plugin/Contents/MacOS/DockTilePlugin"'' ];
    }}
  '';

  installPhase =
    if isDarwin then
      ''
        runHook preInstall

        buildDir="$PWD/build"
        zigOut="$PWD/zig-out"

        ${mkAppBundle {
          name = "Ghostty";
          executable = "ghostty";
          destDir = "$out/Applications";
          binary = "$buildDir/ghostty";
          plist = toPlist (import ./info-plist.nix { inherit (finalAttrs) version; });
          frameworks = [
            {
              name = "Sparkle";
              identifier = "org.sparkle-project.Sparkle";
              dylib = "$buildDir/libSparkle.dylib";
            }
          ];
          plugins = [
            {
              name = "DockTilePlugin";
              identifier = "com.mitchellh.ghostty-dock-tile";
              principalClass = "DockTilePlugin.DockTilePlugin";
              binary = "$buildDir/DockTilePlugin";
            }
          ];
          xibSourceDir = "macos/Sources";
          sdef = "macos/Ghostty.sdef";
          assetCatalog = "macos/Assets.xcassets";
        }}

        # Metal shaders are found by glob (zig writes them under a
        # version-dependent subdir of $zigOut).
        metallib=$(find "$zigOut" -name '*.metallib' -print -quit 2>/dev/null)
        if [ -n "$metallib" ]; then
          nixLog "installing metallib: $metallib"
          cp "$metallib" "$app/Contents/Resources/"
        fi

        ${lib.concatMapStrings (r: ''
          if [ -d "$zigOut/share/${r.src}" ]; then
            nixLog "installing resources: share/${r.src} -> Resources/${r.dest}"
            ${
              if r.dest == "" then
                ''cp -r "$zigOut/share/${r.src}"/* "$app/Contents/Resources/" 2>/dev/null || true''
              else
                ''
                  mkdir -p "$app/Contents/Resources/${r.dest}"
                  cp -r "$zigOut/share/${r.src}"/* "$app/Contents/Resources/${r.dest}/"
                ''
            }
          fi
        '') resourceShares}

        mkdir -p "$terminfo/share" "$shell_integration" "$vim"
        ${lib.concatMapStrings (s: ''
          for candidate in ${lib.concatStringsSep " " (map (c: ''"${c}"'') s.candidates)}; do
            if [ -d "$candidate" ]; then
              cp -r "$candidate" "''$${s.output}/${s.dest}"
              break
            fi
          done
        '') splitOutputs}
        [ -d "$zigOut/share/vim/vimfiles" ] && cp -r "$zigOut/share/vim/vimfiles" "$vim/" || true

        mkdir -p "$out/bin"
        makeWrapper "$app/Contents/MacOS/ghostty" "$out/bin/ghostty"

        runHook postInstall
      ''
    else
      null;

  postFixup =
    if isDarwin then
      ''
        remove-references-to -t ${finalAttrs.deps} "$out/Applications/Ghostty.app/Contents/MacOS/ghostty"
      ''
    else
      ''
        ln -s $man/share/man $out/share/man

        moveToOutput share/terminfo $terminfo
        ln -s $terminfo/share/terminfo $out/share/terminfo

        mv $out/share/ghostty/shell-integration $shell_integration
        ln -s $shell_integration $out/share/ghostty/shell-integration

        mv $out/share/vim/vimfiles $vim
        rmdir $out/share/vim
        ln -s $vim $out/share/vim-plugins

        remove-references-to -t ${finalAttrs.deps} $out/bin/.ghostty-wrapped
      '';

  nativeInstallCheckInputs = lib.optionals (!isDarwin) [
    versionCheckHook
  ];

  doInstallCheck = !isDarwin;

  passthru = {
    tests = lib.optionalAttrs stdenv.hostPlatform.isLinux {
      inherit (nixosTests) allTerminfo;
      nixos = nixosTests.terminal-emulators.ghostty;
    };
    updateScript = ./update.nu;
  };

  meta = {
    description = "Fast, native, feature-rich terminal emulator pushing modern features";
    longDescription = ''
      Ghostty is a terminal emulator that differentiates itself by being
      fast, feature-rich, and native. While there are many excellent terminal
      emulators available, they all force you to choose between speed,
      features, or native UIs. Ghostty provides all three.
    '';
    homepage = "https://ghostty.org/";
    downloadPage = "https://ghostty.org/download";
    changelog = "https://ghostty.org/docs/install/release-notes/${
      builtins.replaceStrings [ "." ] [ "-" ] finalAttrs.version
    }";
    license = lib.licenses.mit;
    mainProgram = "ghostty";
    maintainers = with lib.maintainers; [
      FlameFlag
      jcollie
      pluiedev
      getchoo
    ];
    outputsToInstall = [
      "out"
    ];
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})

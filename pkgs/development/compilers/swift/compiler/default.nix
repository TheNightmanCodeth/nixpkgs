{ lib
, stdenv
, callPackage
, cmake
, bash
, coreutils
, gnugrep
, perl
, ninja
, pkg-config
, clang
, bintools
, python3Packages
, breakpointHook
, git
, fetchpatch
, fetchpatch2
, makeWrapper
, gnumake
, file
, runCommand
, writeShellScriptBin
# For lldb
, libedit
, ncurses
, swig
, libxml2
# Linux-specific
, glibc
, libuuid
# Darwin-specific
, substituteAll
, fixDarwinDylibNames
, runCommandLocal
, xcbuild
, cctools # libtool
, sigtool
, DarwinTools
, CoreServices
, Foundation
, Combine
, MacOSX-SDK
, CLTools_Executables
}:

let
  python3 = python3Packages.python.withPackages (p: [ p.setuptools ]); # python 3.12 compat.

  inherit (stdenv) hostPlatform targetPlatform;

  sources = callPackage ../sources.nix { };

  # Tools invoked by swift at run-time.
  runtimeDeps = lib.optionals stdenv.isDarwin [
    # libtool is used for static linking. This is part of cctools, but adding
    # that as a build input puts an unwrapped linker in PATH, and breaks
    # builds. This small derivation exposes just libtool.
    # NOTE: The same applies to swift-driver, but that is currently always
    # invoked via the old `swift` / `swiftc`. May change in the future.
    (runCommandLocal "libtool" { } ''
      mkdir -p $out/bin
      ln -s ${cctools}/bin/libtool $out/bin/libtool
    '')
  ];

  # There are apparently multiple naming conventions on Darwin. Swift uses the
  # xcrun naming convention. See `configure_sdk_darwin` calls in CMake files.
  swiftOs = if targetPlatform.isDarwin
    then {
      "macos" = "macosx";
      "ios" = "iphoneos";
      #iphonesimulator
      #appletvos
      #appletvsimulator
      #watchos
      #watchsimulator
    }.${targetPlatform.darwinPlatform}
      or (throw "Cannot build Swift for target Darwin platform '${targetPlatform.darwinPlatform}'")
    else targetPlatform.parsed.kernel.name;

  # Apple Silicon uses a different CPU name in the target triple.
  swiftArch = if stdenv.isDarwin && stdenv.isAarch64 then "arm64"
    else targetPlatform.parsed.cpu.name;

  # On Darwin, a `.swiftmodule` is a subdirectory in `lib/swift/<OS>`,
  # containing binaries for supported archs. On other platforms, binaries are
  # installed to `lib/swift/<OS>/<ARCH>`. Note that our setup-hook also adds
  # `lib/swift` for convenience.
  swiftLibSubdir = "lib/swift/${swiftOs}";
  swiftModuleSubdir = if hostPlatform.isDarwin
    then "lib/swift/${swiftOs}"
    else "lib/swift/${swiftOs}/${swiftArch}";

  # And then there's also a separate subtree for statically linked  modules.
  toStaticSubdir = lib.replaceStrings [ "/swift/" ] [ "/swift_static/" ];
  swiftStaticLibSubdir = toStaticSubdir swiftLibSubdir;
  swiftStaticModuleSubdir = toStaticSubdir swiftModuleSubdir;

  # This matches _SWIFT_DEFAULT_COMPONENTS, with specific components disabled.
  swiftInstallComponents = [
    "autolink-driver"
    "compiler"
    # "clang-builtin-headers"
    "libexec"
    "stdlib"
    "sdk-overlay"
    "static-mirror-lib"
    "editor-integration"
    # "tools"
    # "testsuite-tools"
    "toolchain-tools"
    "toolchain-dev-tools"
    "license"
    (if stdenv.isDarwin then "sourcekit-xpc-service" else "sourcekit-inproc")
    "swift-remote-mirror"
    "swift-remote-mirror-headers"
  ];

  # Build a tool used during the build to create a custom clang wrapper, with
  # which we wrap the clang produced by the swift build.
  #
  # This is used in a `POST_BUILD` for the CMake target, so we rename the
  # actual clang to clang-unwrapped, then put the wrapper in place.
  #
  # We replace the `exec ...` command with `exec -a "$0"` in order to
  # preserve $0 for clang. This is because, unlike Nix, we don't have
  # separate wrappers for clang/clang++, and clang uses $0 to detect C++.
  #
  # Similarly, the C++ detection in the wrapper itself also won't work for us,
  # so we base it on $0 as well.
  makeClangWrapper = writeShellScriptBin "nix-swift-make-clang-wrapper" ''
    set -euo pipefail

    targetFile="$1"
    unwrappedClang="$targetFile-unwrapped"

    mv "$targetFile" "$unwrappedClang"
    sed < '${clang}/bin/clang' > "$targetFile" \
      -e 's|^\s*exec|exec -a "$0"|g' \
      -e 's|^\[\[ "${clang.cc}/bin/clang" = \*++ ]]|[[ "$0" = *++ ]]|' \
      -e "s|${clang.cc}/bin/clang|$unwrappedClang|g" \
      -e "s|^\(\s*\)\($unwrappedClang\) \"@\\\$responseFile\"|\1argv0=\$0\n\1${bash}/bin/bash -c \"exec -a '\$argv0' \2 '@\$responseFile'\"|"
    chmod a+x "$targetFile"
  '';

  # Create a tool used during the build to create a custom swift wrapper for
  # each of the swift executables produced by the build.
  #
  # The build produces a `swift-frontend` executable per bootstrap stage. Each
  # of these has one or more aliases via symlinks, and the executable uses $0
  # to detect what tool is called.
  wrapperParams = {
    inherit bintools;
    default_cc_wrapper = clang; # Instead of `@out@` in the original.
    coreutils_bin = lib.getBin coreutils;
    gnugrep_bin = gnugrep;
    suffixSalt = lib.replaceStrings ["-" "."] ["_" "_"] targetPlatform.config;
    use_response_file_by_default = 1;
    swiftDriver = "";
    # NOTE: @prog@ and @progName@ need to be filled elsewhere.
  };
  swiftWrapper = runCommand "swift-wrapper.sh" wrapperParams ''
    substituteAll '${../wrapper/wrapper.sh}' "$out"
  '';
  makeSwiftcWrapper = writeShellScriptBin "nix-swift-make-swift-wrapper" ''
    set -euo pipefail

    targetFile="$1"
    unwrappedSwift="$targetFile-unwrapped"

    mv "$targetFile" "$unwrappedSwift"
    sed < '${swiftWrapper}' > "$targetFile" \
      -e "s|@prog@|'$unwrappedSwift'|g" \
      -e 's|@progName@|"$0"|g'
    chmod a+x "$targetFile"
  '';

  # On Darwin, we need to use BOOTSTRAPPING-WITH-HOSTLIBS because of ABI
  # stability, and have to provide the definitions for the system stdlib.
  appleSwiftCore = stdenv.mkDerivation {
    name = "apple-swift-core";
    dontUnpack = true;

    installPhase = ''
      mkdir -p $out/lib/swift
      cp -r \
        "${MacOSX-SDK}/usr/lib/swift/Swift.swiftmodule" \
        "${MacOSX-SDK}/usr/lib/swift/libswiftCore.tbd" \
        $out/lib/swift/
    '';
  };

in stdenv.mkDerivation {
  pname = "swift";
  inherit (sources) version;

  outputs = [ "out" "lib" "dev" "doc" "man" ];

  nativeBuildInputs = [
    breakpointHook # Pause on failure to allow for entering sandbox via cntr
    cmake
    git
    ninja
    perl # pod2man
    pkg-config
    python3
    makeWrapper
    makeClangWrapper
    makeSwiftcWrapper
  ]
    ++ lib.optionals stdenv.isDarwin [
      xcbuild
      sigtool # codesign
      DarwinTools # sw_vers
      fixDarwinDylibNames
    ];

  buildInputs = [
    # For lldb
    python3
    swig
    libxml2
  ]
    ++ lib.optionals stdenv.isLinux [
      libuuid
    ]
    ++ lib.optionals stdenv.isDarwin [
      CoreServices
      Foundation
      Combine
    ];

  # This is a partial reimplementation of our setup hook. Because we reuse
  # the Swift wrapper for the Swift build itself, we need to do some of the
  # same preparation.
  postHook = ''
    for pkg in "''${pkgsHostTarget[@]}" '${clang.libc}'; do
      for subdir in ${swiftModuleSubdir} ${swiftStaticModuleSubdir} lib/swift; do
        if [[ -d "$pkg/$subdir" ]]; then
          export NIX_SWIFTFLAGS_COMPILE+=" -I $pkg/$subdir"
        fi
      done
      for subdir in ${swiftLibSubdir} ${swiftStaticLibSubdir} lib/swift; do
        if [[ -d "$pkg/$subdir" ]]; then
          export NIX_LDFLAGS+=" -L $pkg/$subdir"
        fi
      done
    done
  '';

  # We invoke cmakeConfigurePhase multiple times, but only need this once.
  dontFixCmake = true;
  # We setup custom build directories.
  dontUseCmakeBuildDir = true;

  unpackPhase = let
    copySource = repo: "cp -r ${sources.${repo}} ${repo}";
  in ''
    mkdir src
    cd src

    ${copySource "cmark"}
    ${copySource "llvm-project"}
    ${copySource "swift"}
    ${copySource "swift-experimental-string-processing"}
    ${copySource "swift-syntax"}
    ${lib.optionalString
      (!stdenv.isDarwin)
      (copySource "swift-corelibs-libdispatch")}

    chmod -R u+w .
  '';

  patchPhase = ''
    # Just patch all the things for now, we can focus this later.
    # TODO: eliminate use of env.
    find -type f -print0 | xargs -0 sed -i \
    ${lib.optionalString stdenv.isDarwin
      "-e 's|/usr/libexec/PlistBuddy|${xcbuild}/bin/PlistBuddy|g'"} \
      -e 's|/usr/bin/env|${coreutils}/bin/env|g' \
      -e 's|/usr/bin/make|${gnumake}/bin/make|g' \
      -e 's|/bin/mkdir|${coreutils}/bin/mkdir|g' \
      -e 's|/bin/cp|${coreutils}/bin/cp|g' \
      -e 's|/usr/bin/file|${file}/bin/file|g'

    echo "swift-wrap"
    patch -p1 -d swift -i ${./patches/swift-wrap.patch}

    echo "swift-nix-resource-root-1"
    patch -p1 -d swift -i ${./patches/swift-nix-resource-root-1.patch}

    echo "swift-nix-resource-root-2"
    patch -p1 -d swift -i ${./patches/swift-nix-resource-root-2.patch}

    echo "swift-linux-fix-libc-paths"
    patch -p1 -d swift -i ${./patches/swift-linux-fix-libc-paths.patch}

    echo "unwrap-built-swift-and-llvm.patch"
    patch -p1 -d swift -i ${./patches/unwrap-built-swift-and-llvm.patch}

    # This patch needs to know the lib output location, so must be substituted
    # in the same derivation as the compiler.
    storeDir="${builtins.storeDir}" \
      substituteAll ${./patches/swift-separate-lib.patch} $TMPDIR/swift-separate-lib.patch
    patch -p1 -d swift -i $TMPDIR/swift-separate-lib.patch

    patch -p1 -d llvm-project -i ${./patches/llvm-module-cache.patch}

    patch -p1 -d llvm-project -i ${./patches/clang-toolchain-dir.patch}
    patch -p1 -d llvm-project -i ${./patches/clang-wrap.patch}

    ${lib.optionalString stdenv.isLinux ''
    substituteInPlace llvm-project/clang/lib/Driver/ToolChains/Linux.cpp \
      --replace 'SysRoot, "/lib' '"", "${glibc}/lib' \
      --replace 'SysRoot, "/usr/lib' '"", "${glibc}/lib' \
      --replace 'LibDir = "lib";' 'LibDir = "${glibc}/lib";' \
      --replace 'LibDir = "lib64";' 'LibDir = "${glibc}/lib";' \
      --replace 'LibDir = X32 ? "libx32" : "lib64";' 'LibDir = "${glibc}/lib";'

    # uuid.h is not part of glibc, but of libuuid.
    sed -i 's|''${GLIBC_INCLUDE_PATH}/uuid/uuid.h|${libuuid.dev}/include/uuid/uuid.h|' \
      swift/stdlib/public/Platform/glibc.modulemap.gyb
    ''}

    # Remove tests for cross compilation, which we don't currently support.
    rm swift/test/Interop/Cxx/class/constructors-copy-irgen-*.swift
    rm swift/test/Interop/Cxx/class/constructors-irgen-*.swift

    # TODO: consider fixing and re-adding. This test fails due to a non-standard "install_prefix".
    rm swift/validation-test/Python/build_swift.swift

    # We cannot handle the SDK location being in "Weird Location" due to Nix isolation.
    rm swift/test/DebugInfo/compiler-flags.swift

    # TODO: Fix issue with ld.gold invoked from script finding crtbeginS.o and crtendS.o.
    rm swift/test/IRGen/ELF-remove-autolink-section.swift

    # The following two tests fail because we use don't use the bundled libicu:
    # [SOURCE_DIR/utils/build-script] ERROR: can't find source directory for libicu (tried /build/src/icu)
    rm swift/validation-test/BuildSystem/default_build_still_performs_epilogue_opts_after_split.test
    rm swift/validation-test/BuildSystem/test_early_swift_driver_and_infer.swift

    # TODO: This test fails for some unknown reason
    rm swift/test/Serialization/restrict-swiftmodule-to-revision.swift

    # This test was flaky in ofborg, see #186476
    rm swift/test/AutoDiff/compiler_crashers_fixed/issue-56649-missing-debug-scopes-in-pullback-trampoline.swift

    patchShebangs .

    ${lib.optionalString (!stdenv.isDarwin) ''
    # NOTE: This interferes with ABI stability on Darwin, which uses the system
    # libraries in the hardcoded path /usr/lib/swift.
    fixCmakeFiles .
    ''}
  '';

  # > clang-15-unwrapped: error: unsupported option '-fzero-call-used-regs=used-gpr' for target 'arm64-apple-macosx10.9.0'
  hardeningDisable = lib.optional stdenv.isAarch64 "zerocallusedregs";

  configurePhase = ''
    export SWIFT_SOURCE_ROOT="$PWD"
    mkdir -p ../build
    cd ../build
    export SWIFT_BUILD_ROOT="$PWD"

    # Most builds set a target, but LLDB doesn't. Harmless on non-Darwin.
    export MACOSX_DEPLOYMENT_TARGET=10.15
  '';

  # These steps are derived from doing a normal build with.
  #
  #   ./swift/utils/build-toolchain test --dry-run
  #
  # But dealing with the custom Python build system is far more trouble than
  # simply invoking CMake directly. Few variables it passes to CMake are
  # actually required or non-default.
  #
  # Using CMake directly also allows us to split up the already large build,
  # and package Swift components separately.
  #
  # Besides `--dry-run`, another good way to compare build changes between
  # Swift releases is to diff the scripts:
  #
  #   git diff swift-5.6.3-RELEASE..swift-5.7-RELEASE -- utils/build*
  #
  buildPhase = ''
    # Create bootstrap dirs
    mkdir -p $SWIFT_BUILD_ROOT/stage{0,1,2}
    echo "=== BUILD STAGE 0 ==="
    # Build stage 0
    $SWIFT_SOURCE_ROOT/swift/utils/build-script \
        --release-debuginfo \
        --install-destdir="$SWIFT_BUILD_ROOT/stage0" \
        --build-swift-libexec=false \
        --llvm-install-components='llvm-ar;llvm-cov;llvm-profdata;IndexStore;clang;clang-resource-headers;compiler-rt;clangd;lld;LTO;clang-features-file' \
        --llvm-targets-to-build=host \
        --skip-build-benchmarks \
        --skip-early-swift-driver \
        --skip-test-early-swift-driver \
        --skip-early-swiftsyntax \
        --skip-test-swiftsyntax \
        --extra-cmake-options="-DSWIFT_USE_LINKER=lld" \
        --extra-cmake-options="-DBUILD_TESTING=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TESTS=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TEST_BINARIES=NO" \
        --extra-cmake-options="-DCOMPILER_RT_BUILD_ORC=NO" \
        --skip-test-cmark \
        --skip-test-linux \
        --skip-test-swift \
        --install-all

    echo "=== INSTALL STAGE 0 ==="
    # Install stage 0
    ## Move unwrapped clang over
    CMAKE_INSTALL_PREFIX=$SWIFT_BUILD_ROOT/stage0
    LLVM_INSTALL_COMPONENTS='llvm-ar;llvm-cov;llvm-profdata;IndexStore;clang;clang-resource-headers;compiler-rt;clangd;lld;LTO;clang-features-file'
    mv $SWIFT_BUILD_ROOT/Ninja-ReleaseAssert/llvm-linux-aarch64/bin/clang-17{-unwrapped,}
    cd $SWIFT_BUILD_ROOT/Ninja-ReleaseAssert/llvm-linux-aarch64
    ninjaInstallPhase
    unset CMAKE_INSTALL_PREFIX
    unset LLVM_INSTALL_COMPONENTS

    cd $SWIFT_BUILD_ROOT/Ninja-ReleaseAssert/cmark-linux-aarch64
    ninjaInstallPhase

    echo "=== BUILD STAGE 1 ==="
    # Build stage 1
    export OLDPATH="$PATH"
    export PATH="$SWIFT_BUILD_ROOT/stage0/usr/bin:$OLDPATH"
    $SWIFT_SOURCE_ROOT/swift/utils/build-script \
        --release \
        --install-destdir="$SWIFT_BUILD_ROOT/stage1" \
        --extra-cmake-options="-DSWIFT_USE_LINKER=lld" \
        --extra-cmake-options="-DBUILD_TESTING=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TESTS=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TEST_BINARIES=NO" \
        --extra-cmake-options="-DCOMPILER_RT_BUILD_ORC=NO" \
        --build-swift-libexec=false \
        --cmark --skip-test-cmark \
        --foundation --skip-test-foundation \
        --libdispatch --skip-test-libdispatch \
        --llbuild --skip-test-llbuild \
        --skip-build-benchmarks \
        --skip-build-llvm \
        --skip-test-linux \
        --skip-test-swift \
        --swift-driver --skip-test-swift-driver \
        --swiftpm --skip-test-swiftpm \
        --xctest --skip-test-xctest \
        --install-all

    echo "=== BUILD STAGE 2 ==="
    # Build stage 2
    export PATH="$SWIFT_BUILD_ROOT/stage1/usr/bin:$OLDPATH"
    $SWIFT_SOURCE_ROOT/swift/utils/build-script \
        --verbose-build \
        --release \
        --install-destdir="$SWIFT_BUILD_ROOT/stage2" \
        --extra-cmake-options="-DSWIFT_USE_LINKER=lld" \
        --extra-cmake-options="-DBUILD_TESTING=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TESTS=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TEST_BINARIES=NO" \
        --extra-cmake-options="-DCOMPILER_RT_BUILD_ORC=NO" \
        --build-swift-libexec=false \
        --foundation --skip-test-foundation \
        --indexstore-db --skip-test-indexstore-db \
        --libdispatch --skip-test-libdispatch \
        --llbuild --skip-test-llbuild \
        --lldb --skip-test-lldb \
        --skip-build-benchmarks \
        --skip-build-llvm \
        --skip-test-linux \
        --skip-test-swift \
        --sourcekit-lsp --skip-test-sourcekit-lsp \
        --swift-driver --skip-test-swift-driver \
        --swift-install-components='autolink-driver;compiler;clang-resource-dir-symlink;stdlib;swift-remote-mirror;sdk-overlay;static-mirror-lib;toolchain-tools;license;sourcekit-inproc' \
        --swiftdocc --skip-test-swiftdocc \
        --swiftpm --skip-test-swiftpm \
        --xctest --skip-test-xctest \
        --install-all
    echo "=== BUILD FINAL ==="
    # Final
    mkdir $SWIFT_BUILD_ROOT/final
    export PATH="$SWIFT_BUILD_ROOT/stage2/usr/bin:$OLDPATH"
    $SWIFT_SOURCE_ROOT/swift/utils/build-script \
        --release \
        --install-destdir="$SWIFT_BUILD_ROOT/final" \
        --extra-cmake-options="-DSWIFT_USE_LINKER=lld" \
        --extra-cmake-options="-DBUILD_TESTING=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TESTS=NO" \
        --extra-cmake-options="-DSWIFT_INCLUDE_TEST_BINARIES=NO" \
        --extra-cmake-options="-DCOMPILER_RT_BUILD_ORC=NO" \

    echo "=== INSTALL FINAL ==="
    # Install final
    ## Move swift-frontend-unwrapped
    CMAKE_INSTALL_PREFIX="$SWIFT_BUILD_ROOT/final"
    mv $SWIFT_BUILD_ROOT/Ninja-ReleaseAssert/swift-linux-aarch64/bin/swift-frontend{-unwrapped,}
    cd $SWIFT_BUILD_ROOT/Ninja-ReleaseAssert/swift-linux-aarch64
    ninjaInstallPhase
  '';

  # TODO: ~50 failing tests on x86_64-linux. Other platforms not checked.
  doCheck = false;
  nativeCheckInputs = [ file ];
  # TODO: consider using stress-tester and integration-test.
  checkPhase = ''
    cd $SWIFT_BUILD_ROOT/swift
    checkTarget=check-swift-all
    ninjaCheckPhase
    unset checkTarget
  '';

  installPhase = ''
    # Undo the clang and swift wrapping we did for the build.
    # (This happened via patches to cmake files.)
    # cd $SWIFT_BUILD_ROOT
    # mv llvm/bin/clang-16{-unwrapped,}
    # mv swift/bin/swift-frontend{-unwrapped,}

    mkdir $out $lib

    # Install clang binaries only. We hide these with the wrapper, so they are
    # for private use by Swift only.
    cd $SWIFT_BUILD_ROOT/final
    moveToOutput "./*" "$out"
    # Separate $lib output here, because specific logic follows.
    # Only move the dynamic run-time parts, to keep $lib small. Every Swift
    # build will depend on it.
    moveToOutput "lib/swift" "$lib"
    moveToOutput "lib/libswiftDemangle.*" "$lib"

    # This link is here because various tools (swiftpm) check for stdlib
    # relative to the swift compiler. It's fine if this is for build-time
    # stuff, but we should patch all cases were it would end up in an output.
    ln -s $lib/lib/swift $out/lib/swift

    # Swift has a separate resource root from Clang, but locates the Clang
    # resource root via subdir or symlink. Provide a default here, but we also
    # patch Swift to prefer NIX_CC if set.
    #
    # NOTE: We don't symlink directly here, because that'd add a run-time dep
    # on the full Clang compiler to every Swift executable. The copy here is
    # just copying the 3 symlinks inside to smaller closures.
    mkdir $lib/lib/swift/clang
    cp -P ${clang}/resource-root/* $lib/lib/swift/clang/

    ${lib.optionalString stdenv.isDarwin ''
    # Install required library for ObjC interop.
    # TODO: Is there no source code for this available?
    cp -r ${CLTools_Executables}/usr/lib/arc $out/lib/arc
    ''}
  '';

  preFixup = lib.optionalString stdenv.isLinux ''
    # This is cheesy, but helps the patchelf hook remove /build from RPATH.
    cd $SWIFT_BUILD_ROOT/..
    mv build buildx
  '';

  postFixup = lib.optionalString stdenv.isDarwin ''
    # These libraries need to use the system install name. The official SDK
    # does the same (as opposed to using rpath). Presumably, they are part of
    # the stable ABI. Not using the system libraries at run-time is known to
    # cause ObjC class conflicts and segfaults.
    declare -A systemLibs=(
      [libswiftCore.dylib]=1
      [libswiftDarwin.dylib]=1
      [libswiftSwiftOnoneSupport.dylib]=1
      [libswift_Concurrency.dylib]=1
    )

    for systemLib in "''${!systemLibs[@]}"; do
      install_name_tool -id /usr/lib/swift/$systemLib $lib/${swiftLibSubdir}/$systemLib
    done

    for file in $out/bin/swift-frontend $lib/${swiftLibSubdir}/*.dylib; do
      changeArgs=""
      for dylib in $(otool -L $file | awk '{ print $1 }'); do
        if [[ ''${systemLibs["$(basename $dylib)"]} ]]; then
          changeArgs+=" -change $dylib /usr/lib/swift/$(basename $dylib)"
        elif [[ "$dylib" = */bootstrapping1/* ]]; then
          changeArgs+=" -change $dylib $lib/lib/swift/$(basename $dylib)"
        fi
      done
      if [[ -n "$changeArgs" ]]; then
        install_name_tool $changeArgs $file
      fi
    done

    wrapProgram $out/bin/swift-frontend \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
  '';

  passthru = {
    inherit
      swiftOs swiftArch
      swiftModuleSubdir swiftLibSubdir
      swiftStaticModuleSubdir swiftStaticLibSubdir;

    # Internal attr for the wrapper.
    _wrapperParams = wrapperParams;
  };

  meta = {
    description = "Swift Programming Language";
    homepage = "https://github.com/apple/swift";
    maintainers = lib.teams.swift.members;
    license = lib.licenses.asl20;
    platforms = with lib.platforms; linux ++ darwin;
    # Swift doesn't support 32-bit Linux, unknown on other platforms.
    badPlatforms = lib.platforms.i686;
    timeout = 86400; # 24 hours.
  };
}

{ pkgs, lib, config, inputs, ... }:

let
  zephyrPkgs = inputs.zephyr-nix.packages.${pkgs.stdenv.system};

  # Zephyr SDK 0.16.x matches the Zephyr 3.5 line pinned by config/west.yml
  # (refil/zmk branch adv360-z3.5-2). Only the ARM target is needed (nRF52840).
  zephyrSdk = zephyrPkgs.sdk-0_16.override { targets = [ "arm-zephyr-eabi" ]; };

  # The ZMK Studio (clique) build generates protobuf code via nanopb, whose
  # protoc wrapper needs grpcio-tools, protobuf and pkg_resources (setuptools)
  # on top of Zephyr's own requirements.txt.
  pythonEnv = zephyrPkgs.pythonEnv.override {
    extraPackages = ps: [ ps.setuptools ps.protobuf ps.grpcio-tools ];
  };

  # CMake 3.x from a pinned nixpkgs; Zephyr 3.5 breaks under CMake 4.
  cmake3 = inputs.nixpkgs-cmake3.legacyPackages.${pkgs.stdenv.system}.cmake;
in
{
  packages = [
    zephyrSdk
    pythonEnv              # python + west + Zephyr's scripts/requirements.txt
    cmake3                 # must stay 3.x -- do NOT add pkgs.cmake (4.x)
    pkgs.ninja
    pkgs.dtc
    pkgs.gperf
    pkgs.git
    pkgs.wget
    pkgs.util-linux        # lsblk/findmnt for bin/flash.sh
    pkgs.coreutils         # numfmt, sync -f for bin/flash.sh
  ];

  env = {
    ZEPHYR_TOOLCHAIN_VARIANT = "zephyr";
    # zephyr-nix's SDK setup-hook exports the same value; set explicitly so the
    # shell does not depend on hook execution order.
    ZEPHYR_SDK_INSTALL_DIR = "${zephyrSdk}";
    # nixpkgs' `west` is a wrapper that prepends a BARE python3 (no
    # site-packages) to PATH, so build steps spawned by west that use a
    # `#!/usr/bin/env python3` shebang (e.g. nanopb's protoc wrapper for the
    # ZMK Studio build) would lose all Python deps. Pointing PYTHONPATH at the
    # full env's site-packages keeps that bare interpreter functional.
    PYTHONPATH = "${pythonEnv}/${pythonEnv.sitePackages}";
  };

  scripts.init-west = {
    description = "First-time west workspace setup (idempotent)";
    exec = ''
      set -euo pipefail
      cd "$DEVENV_ROOT"
      if [ ! -d .west ]; then
        west init -l config
      fi
      west update
      west zephyr-export
    '';
  };

  scripts.update-deps = {
    description = "Re-fetch ZMK/Zephyr (west.yml pins moving branch adv360-z3.5-2)";
    exec = ''
      set -euo pipefail
      cd "$DEVENV_ROOT"
      west update
    '';
  };

  scripts.build = {
    description = "Build both halves natively; outputs firmware/<ts>-<sha>-{left,right}-clique.uf2";
    exec = ''
      set -euo pipefail
      cd "$DEVENV_ROOT"
      if [ ! -d .west ]; then
        echo "west workspace missing -- run init-west first" >&2
        exit 1
      fi
      export TIMESTAMP="$(date -u +%Y%m%d%H%M)"
      export COMMIT="$(git rev-parse --short HEAD)"
      export BUILD_RIGHT="''${BUILD_RIGHT:-true}"
      # version.dtsi is generated; restore if tracked, remove if not
      # (untracked at current HEAD -- plain `git checkout` would fail).
      trap 'git checkout -- config/version.dtsi 2>/dev/null || rm -f config/version.dtsi' EXIT
      bin/get_version_local.sh clique > /dev/null
      bin/build.sh
    '';
  };

  scripts.build-left = {
    description = "Build only the left half";
    exec = ''BUILD_RIGHT=false exec build'';
  };

  scripts.build-right = {
    description = "Build only the right half";
    exec = ''
      set -euo pipefail
      cd "$DEVENV_ROOT"
      TIMESTAMP="$(date -u +%Y%m%d%H%M)"
      COMMIT="$(git rev-parse --short HEAD)"
      trap 'git checkout -- config/version.dtsi 2>/dev/null || rm -f config/version.dtsi' EXIT
      bin/get_version_local.sh clique > /dev/null
      west build -s zmk/app -p -d build/right -b adv360_right -- -DZMK_CONFIG="$DEVENV_ROOT/config"
      cp build/right/zephyr/zmk.uf2 "firmware/$TIMESTAMP-$COMMIT-right-clique.uf2"
    '';
  };

  scripts.flash = {
    description = "Build and interactively flash both halves over USB (see --help)";
    exec = ''exec "$DEVENV_ROOT/bin/flash.sh" "$@"'';
  };

  enterShell = ''
    echo "Adv360 Pro ZMK dev shell (Zephyr SDK ${zephyrSdk.version or "0.16.x"}, native west build)"
    echo "  init-west     first-time west workspace setup"
    echo "  update-deps   pull latest ZMK (moving branch adv360-z3.5-2)"
    echo "  build         build both halves -> firmware/"
    echo "  build-left | build-right"
    echo "  flash         build + guided flash of both halves"
    if [ ! -d "$DEVENV_ROOT/.west" ]; then
      echo ""
      echo "NOTE: west workspace not initialised yet -- run: init-west"
    fi
  '';
}

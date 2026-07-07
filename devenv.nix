{ pkgs, ... }:

{
  # Firmware is built by GitHub Actions; this shell only provides the tools
  # bin/flash.sh needs to fetch and flash the CI artifacts.
  packages = [
    pkgs.curl        # download artifacts from nightly.link
    pkgs.unzip       # host has no unzip
    pkgs.util-linux  # findmnt / lsblk
    pkgs.coreutils   # od, numfmt, sync -f
  ];

  scripts.flash = {
    description = "Fetch CI-built firmware and interactively flash both halves (flash --help)";
    exec = ''exec "$DEVENV_ROOT/bin/flash.sh" "$@"'';
  };

  enterShell = ''
    echo "Adv360 Pro ZMK shell -- run 'flash' to fetch the latest CI firmware and flash it ('flash --help' for options)"
  '';
}

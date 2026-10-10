# Home Manager module: `programs.opencode-desktop`.
#
# Self-contained: the flake's overlay is bundled via `nixpkgs.overlays`
# below, so a single import suffices:
#
# ```nix
# {
#   imports = [ inputs.opencode-desktop-nix.homeManagerModules.default ];
#   programs.opencode-desktop.enable = true;
# }
# ```
#
# NOTE: the option *definitions* live in `modules/generic/options.nix`,
# shared with the NixOS module. Both define `programs.opencode-desktop`;
# see the NixOS module for what happens when a configuration imports both.
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.opencode-desktop;
  # `extraArgs` reaches the binary through an override on the package, so
  # `config.programs.opencode-desktop.package` always reflects it.
  package =
    if cfg.extraArgs == [ ] then cfg.package else cfg.package.override { inherit (cfg) extraArgs; };
in
{
  _class = "homeManager";
  _file = ./default.nix;

  imports = [
    # keep-sorted start
    ../generic/options.nix
    # keep-sorted end
  ];

  config = lib.mkIf cfg.enable {
    # Bundle the flake's overlay so consumers need only this import.
    # Imported by relative path (not via flake `self`) to avoid
    # self-reference cycles. `overlays.default` remains exposed for manual
    # use.
    nixpkgs.overlays = [ (import ../../nix/overlay.nix) ];

    # `home.packages` (not `xdg.dataFiles`) also works outside NixOS, where
    # there is no `/run/current-system/sw/share` in `XDG_DATA_DIRS` — the
    # package's `$out/share/applications` and `$out/share/icons` are
    # symlinked onto PATH, and the desktop environment finds the menu entry
    # through the user-level XDG data dirs it builds from those.
    home.packages = [ package ];
  };
}

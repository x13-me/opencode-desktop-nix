# NixOS module: `programs.opencode-desktop`.
#
# Self-contained: the flake's overlay is bundled via `nixpkgs.overlays`
# below, so a single import suffices:
#
# ```nix
# {
#   imports = [ inputs.opencode-desktop-nix.nixosModules.default ];
#   programs.opencode-desktop.enable = true;
# }
# ```
#
# NOTE: the option *definitions* live in `modules/generic/options.nix`,
# shared with the Home Manager module. Both modules define
# `programs.opencode-desktop`, so importing both into one evaluation (home
# -manager as a NixOS submodule) yields one definition — but BOTH config
# blocks run, adding the package to `environment.systemPackages` *and*
# `home.packages`. That is harmless (same package), not an error.
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
  _class = "nixos";
  _file = ./default.nix;

  imports = [
    # keep-sorted start
    ../generic/options.nix
    # keep-sorted end
  ];

  config = lib.mkMerge [
    {
      # Bundle the flake's overlay so consumers need only this import.
      # Imported by relative path (not via flake `self`) to avoid
      # self-reference cycles. `overlays.default` remains exposed for manual
      # use.
      nixpkgs.overlays = [ (import ../../nix/overlay.nix) ];
    }
    (lib.mkIf cfg.enable {
      # The package installs its `.desktop` file and icons into
      # `$out/share`, which NixOS already scans through
      # `/run/current-system/sw/share` in `XDG_DATA_DIRS` — no explicit
      # desktop-file/icon wiring needed.
      environment.systemPackages = [ package ];
    })
  ];
}

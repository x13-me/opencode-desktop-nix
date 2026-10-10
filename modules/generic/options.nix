# Option definitions shared by the NixOS and Home Manager modules.
#
# Both modules expose the same `programs.opencode-desktop` namespace, and
# both import THIS file for the definitions. Importing the same path twice
# is deduplicated by the module system, so a Home Manager configuration
# running as a NixOS submodule can import both modules without producing
# "option defined in multiple files" errors.
#
# Keep the definitions here; the modules own only their `config` blocks.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  opencodeLib = import ../../lib { inherit lib; };

  # Optional flake package set, injected via `_module.args.extpkgs` in any
  # module of the same evaluation; falls back to the overlay package
  # otherwise.
  # NOTE: read via `config._module.args`, not an `@args` capture — extra
  # module args only reach *named* formals (see `applyModuleArgs`), so an
  # `@args` capture would silently miss the injection.
  extpkgs = config._module.args.extpkgs or pkgs;
  requirePackage =
    name:
    if builtins.hasAttr name extpkgs then
      extpkgs.${name}
    else
      throw "opencode-desktop-nix: `${name}` not found — apply the overlay (`nixpkgs.overlays = [ inputs.opencode-desktop-nix.overlays.default ];`) or inject the flake package set (`_module.args.extpkgs = inputs.opencode-desktop-nix.legacyPackages.\${pkgs.stdenv.hostPlatform.system};`).";
in
{
  # NOTE: no keep-sorted markers on this set on purpose — keep-sorted
  # sorts raw lines and would scramble multi-line option definitions.
  options.programs.opencode-desktop = {
    enable = lib.mkEnableOption "the OpenCode desktop app";

    package = opencodeLib.mkPackageOption {
      default = requirePackage "opencode-desktop";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--ozone-platform-hint=x11" ];
      description = ''
        Extra command-line flags appended to the app's wrapper.

        Passed to the stock `opencode-desktop` package, which must accept
        an `extraArgs` argument; evaluation fails fast otherwise, as with
        a custom `package` that does not.

        Nothing is set by default; the package already passes
        `--ozone-platform-hint=auto` so that UI size is correct on
        fractional-scale displays (under XWayland Chromium never learns
        the compositor's scale, renders at 1x, and gets upscaled). These
        flags are appended after the package's own, and Chromium keeps the
        last occurrence of a repeated switch, so anything here wins:

        ```nix
        extraArgs = [ "--ozone-platform-hint=x11" ];
        ```

        Expect a cosmetic `'--ozone-platform=wayland' is not compatible
        with Vulkan` notice at startup; per electron#50462 GPU
        compositing still works. Verified on an Intel Iris Xe (i915) +
        KDE Wayland session: the GPU child receives
        `--ozone-platform=wayland --render-node-override=...` and
        compositing is healthy.
      '';
    };
  };
}

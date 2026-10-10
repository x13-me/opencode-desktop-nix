# OpenCode desktop flake helpers, written in nixdoc style (`/** ... */`).
#
# Extensible via `lib.extend` / `makeExtensible`:
#
# ```nix
# myLib = opencodeLib.extend (final: prev: { myHelper = ...; });
# ```
{ lib }:
lib.makeExtensible (_final: {
  /**
    Nix systems this flake builds for.

    Single source of truth: `nix/default.nix` derives `forAllSystems`
    from this list, and package `meta.platforms` mirrors it.
  */
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  /**
    Map a Nix system to the upstream OpenCode desktop deb arch naming.

    Upstream ships `.deb` artifacts under Debian names (`amd64` / `arm64`),
    not RPM names (`x86_64` / `aarch64`).

    # Arguments

    - `versions`: the parsed contents of `versions.nix`
      (`systems.<system>.arch`).
    - `system`: e.g. `"x86_64-linux"`.

    Fails fast on unknown systems so a bad matrix entry errors at
    evaluation time, not mid-build.

    # Example

    ```nix
    archOf versions "aarch64-linux" # => "arm64"
    ```
  */
  archOf =
    versions: system:
    versions.systems.${system}.arch
      or (throw "opencode-desktop-nix: no arch mapping for system ${system}");

  /**
    Standard `package` option for the OpenCode desktop modules.

    Defaults to the flake's own `opencode-desktop` (from the overlay this
    module bundles, or from `_module.args.extpkgs`). The default throws
    with both fixes named when neither supplies it, rather than
    silently evaluating to something unusable.

    # Arguments

    - `default`: the package to use.
  */
  mkPackageOption =
    {
      default,
    }:
    lib.mkOption {
      type = lib.types.package;
      inherit default;
      defaultText = lib.literalExpression "pkgs.opencode-desktop";
      description = ''
        The OpenCode desktop package to install.

        Provided by this flake's overlay (bundled by the NixOS and
        Home Manager modules) or by an injected flake package set
        (`_module.args.extpkgs`).
      '';
    };
})

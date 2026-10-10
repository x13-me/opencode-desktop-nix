# Main flake outputs (imported by the thin `flake.nix`).
#
# Small-flake layout, no flake-parts/flake-utils/haumea:
# `forAllSystems` is just `lib.genAttrs` over `legacyPackages`.
{ nixpkgs, ... }:
let
  inherit (nixpkgs) lib;
  opencodeLib = import ../lib { inherit lib; };

  inherit (opencodeLib) systems;

  forAllSystems = fn: lib.genAttrs systems (s: fn nixpkgs.legacyPackages.${s});

  scopeFor = pkgs: import ../packages { inherit pkgs; };

  publicNames = [
    # keep-sorted start
    "opencode-desktop"
    # keep-sorted end
  ];

  isUsableOn =
    pkgs: _: pkg:
    lib.isDerivation pkg
    && !(pkg.meta.broken or false)
    && lib.meta.availableOn pkgs.stdenv.hostPlatform pkg;

  packages = forAllSystems (
    pkgs:
    let
      scope = scopeFor pkgs;
      public = lib.filterAttrs (isUsableOn pkgs) (lib.getAttrs publicNames scope);
    in
    public
    // lib.optionalAttrs (public ? opencode-desktop) {
      default = public.opencode-desktop;
    }
  );

  formatterFor = pkgs: pkgs.callPackage ./formatter.nix { };

  homeManagerModules = {
    default = ../modules/home-manager/default.nix;
    # Legacy alias (helium-nix compat): `homeManagerModules.opencode-desktop`.
    opencode-desktop = ../modules/home-manager/default.nix;
  };

  nixosModule = ../modules/nixos/default.nix;
in
{
  inherit homeManagerModules packages;

  apps = forAllSystems (
    pkgs:
    let
      system = pkgs.stdenv.hostPlatform.system;
      built = packages.${system};
    in
    lib.optionalAttrs (built ? opencode-desktop) {
      opencode-desktop = {
        type = "app";
        program = "${built.opencode-desktop}/bin/opencode-desktop";
      };
      default = {
        type = "app";
        program = "${built.opencode-desktop}/bin/opencode-desktop";
      };
    }
  );

  # Raw scope (unfiltered); non-derivations from `makeScope` bookkeeping
  # (`callPackage`, `overrideScope`, …) are dropped so every exposed member
  # is a real package.
  legacyPackages = forAllSystems (pkgs: lib.filterAttrs (_: lib.isDerivation) (scopeFor pkgs));

  overlays = {
    default = import ./overlay.nix;
  };

  devShells = forAllSystems (
    pkgs:
    let
      formatter = formatterFor pkgs;
    in
    {
      default = pkgs.mkShellNoCC {
        packages = [
          # keep-sorted start
          pkgs.dpkg
          pkgs.git
          pkgs.just
          pkgs.nixfmt-rfc-style
          # keep-sorted end
        ]
        ++ formatter.runtimeInputs;
        env.DIRENV_LOG_FORMAT = "";
      };
    }
  );

  checks = forAllSystems (
    pkgs:
    let
      formatter = formatterFor pkgs;
    in
    {
      formatting =
        pkgs.runCommandLocal "opencode-desktop-formatting-check"
          {
            src = lib.cleanSource ../.;
            nativeBuildInputs = [ formatter ];
          }
          ''
            cd "$src"
            treefmt --tree-root-file flake.nix --ci
            touch "$out"
          '';
    }
  );

  formatter = forAllSystems formatterFor;

  nixosModules = {
    default = nixosModule;
    # Legacy alias (helium-nix compat): `nixosModules.opencode-desktop`.
    opencode-desktop = nixosModule;
  };

  # Canonical name is `homeManagerModules`; `homeModules` is a compat alias.
  homeModules = homeManagerModules;

  hydraJobs =
    let
      jobsFor =
        system:
        let
          available = packages.${system};
          present = lib.filter (name: available ? ${name}) publicNames;
        in
        map (name: lib.nameValuePair "${name}-${system}" available.${name}) present;
    in
    lib.listToAttrs (lib.concatMap jobsFor systems);

  lib = opencodeLib;
}

# System-independent overlay: `prev.callPackage` only, never
# `self.packages.${system}`.
#
# Referencing flake outputs from an overlay pins it to this flake's nixpkgs
# revision and breaks composition with other overlays; rebuilding from
# `./packages` keeps the overlay freely composable.
#
# NOTE: this entry deliberately shadows nixpkgs' own `opencode-desktop`,
# which is a from-source build of the 1.x desktop line. This flake packages
# the official 2.x prebuilt `.deb` instead.
#
# NOTE: no keep-sorted markers here on purpose — keep-sorted sorts raw
# lines, so it must only guard single-line entry lists (see module
# `imports`). Multi-line bindings would be scrambled.
_: prev: {
  opencode-desktop = prev.callPackage ../packages/opencode-desktop/package.nix { };
}

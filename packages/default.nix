# Package scope.
#
# NOTE: no keep-sorted markers here on purpose — keep-sorted sorts raw
# lines, so it must only guard single-line entry lists (see `imports` in the
# modules). Multi-line bindings would be scrambled.
{ pkgs }:
pkgs.lib.makeScope pkgs.newScope (_self: {
  opencode-desktop = _self.callPackage ./opencode-desktop/package.nix { };
})

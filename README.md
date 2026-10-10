# opencode-desktop-nix

The official OpenCode desktop app (Electron, 2.x) packaged for Nix from
upstream's prebuilt Linux `.deb` — no source build, no asar surgery.

```nix
{
  inputs.opencode-desktop-nix.url = "github:x13-me/opencode-desktop-nix";

  # NixOS
  imports = [ inputs.opencode-desktop-nix.nixosModules.default ];
  programs.opencode-desktop.enable = true;

  # …or Home Manager
  # imports = [ inputs.opencode-desktop-nix.homeManagerModules.default ];
  # programs.opencode-desktop.enable = true;
}
```

## Layout

| Path | Contents |
| --- | --- |
| `flake.nix` | thin root; all outputs in `./nix` |
| `nix/default.nix` | `packages`, `apps`, `overlays`, `checks`, `hydraJobs`, … |
| `nix/overlay.nix` | `opencode-desktop` overlay |
| `nix/formatter.nix` | treefmt: nixfmt + deadnix + statix + keep-sorted |
| `lib/default.nix` | nixdoc helpers (`systems`, `archOf`, option builders) |
| `packages/opencode-desktop/` | the derivation |
| `modules/` | NixOS + Home Manager modules (shared options in `generic/`) |
| `versions.nix` | machine-updated; the sole version/hash source |

## Notes

- **Namespaces nixpkgs' `opencode-desktop`.** The overlay entry shadows
  nixpkgs' own `opencode-desktop` (1.18.31, built from source with
  `electron-builder`). This flake packages the official 2.x prebuilt `.deb`.
- **Auto-update is disabled by design.** `resources/app-update.yml` is
  removed so `electron-updater` can never dpkg-install an unpatched upstream
  binary over this store path.
- **`chrome-sandbox` is not shipped.** The store cannot hold a setuid bit;
  Chromium's unprivileged user-namespace sandbox covers it (nixpkgs defaults
  `security.allowUserNamespaces = true`).
- **GL stack is bundled.** `libglvnd` + `mesa` go on the wrapper's
  `LD_LIBRARY_PATH`. On NixOS nothing resolves through `ld.so.cache`, so a
  prebuilt bundle with a self-contained RPATH must carry the driver itself.
- **Systems:** `x86_64-linux` and `aarch64-linux`, from
  `opencode.ai/files/bin/<version>/opencode-desktop-linux-{amd64,arm64}.deb`.

The wrapper passes these by default:

| Flag | Why |
| --- | --- |
| `--ozone-platform-hint=auto` | talk to the compositor directly, fall back to X11 |
| `--force-device-scale-factor=1` | the app ignores the fractional scale it is handed |
| `--enable-features=WaylandWindowDecorations` | let the app draw its own frame |
| `--enable-wayland-ime=true` | IME over Wayland text-input, not XIM |
| `--wayland-text-input-version=3` | the text-input version the above negotiates |

The last three mirror nixpkgs' from-source `opencode-desktop`. Note that
Chromium *merges* `--enable-features` into its own list rather than
letting the last occurrence win, so ours survives into the GPU and
renderer children. Despite `WaylandWindowDecorations` being enabled, KWin
still draws the frame (`noBorder=false`) — Electron does not opt into
client-side decorations here, so this costs nothing visually.

### Scaling on fractional-scale displays

The wrapper passes `--ozone-platform-hint=auto` by default. Under XWayland
Chromium never learns the compositor's fractional scale — it renders at 1×
and XWayland upscales the result, so on a 1.4×/1.7× display the UI looks
far too large. `auto` makes Electron talk to the compositor directly when
one is offered and fall back to X11 otherwise, so X11-only sessions are
unaffected.

Override it if you need to:

```nix
programs.opencode-desktop = {
  enable = true;
  extraArgs = [ "--ozone-platform-hint=x11" ];
};
```

`extraArgs` is appended after the package's own defaults, and Chromium
keeps the last occurrence of a repeated switch, so this wins.

Known cosmetic noise: this prints `'--ozone-platform=wayland' is not
compatible with Vulkan` at startup. Per
[electron#50462](https://github.com/electron/electron/issues/50462) that
message is cosmetic and GPU compositing still works; the issue's own
reporter confirmed `gpu_compositing: enabled` / `webgl: enabled` on an
Intel integrated GPU under Wayland with these same flags.

### UI still too large on fractional-scale desktops

Native Wayland gets the app *onto* Wayland, but on the development
machine (DP-2, 3840×2160, KWin scale 1.7) the UI still rendered at
roughly twice the size of native KDE apps. Chromium does receive the
right value — it binds `wp_fractional_scale_manager_v1` and logs
`preferred_scale(204)` (= 1.7) — it just does not end up applying it to
rendering.

The symptom is *crisp but oversized*, which distinguishes it from the
XWayland case: a compositor-upscaled 1× buffer is blurry, a
double-scaled buffer is sharp and too big.

`--force-device-scale-factor=1` fixes it, and the UI then matches the KDE
window decorations pixel for pixel. It is **not** a sensible package
default — it pins the scale and ignores the display, so it is wrong on
any output you did not tune it for (this machine also has a 1.4× eDP-1).
Pass it yourself if you hit this:

```nix
programs.opencode-desktop = {
  enable = true;
  extraArgs = [ "--force-device-scale-factor=1" ];
};
```

### Verified on this machine

On an Intel Iris Xe (i915) + KDE Wayland session, with no configuration
and no session variables, the default build stays alive and its GPU child
receives `--ozone-platform=wayland
--render-node-override=/dev/dri/renderD128`.

Note when testing: a `timeout … | grep` harness will manufacture false
failures. SIGTERM puts Chromium into its shutdown path, which logs
`GPU process isn't usable` while tearing children down. Check whether the
process is still alive after ~45s instead of counting matches in a killed
run.

## Development

```sh
nix fmt              # format
nix flake check      # eval + formatting check
nix build .#opencode-desktop
```

`ci.yml` evaluates all systems and gates on `nix fmt -- --ci`;
`update-opencode-desktop-main.yml` resolves the latest version from the
opencode.ai stable-channel redirect, rewrites `versions.nix`, and rebuilds.
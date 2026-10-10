# OpenCode desktop: the upstream Electron build, repackaged from the
# official Linux `.deb` (no compiling, no asar surgery).
#
# Upstream ships a real Electron bundle under `/opt/OpenCode`, with
# `resources/app.asar` holding the app and a standalone `opencode-cli`
# sidecar. Everything below is packaging only:
#
#   * `autoPatchelfHook` resolves the deb's DT_NEEDED libraries into
#     store RPATHs. `libffmpeg.so` stays bundled next to the binary and is
#     found through the `$ORIGIN` RPATH upstream already ships (re-asserted
#     in `postFixup`, because patchelf would otherwise replace it).
#   * The four libraries Electron `dlopen()`s rather than links
#     (`libnotify`, `libsecret`, `libpulseaudio`, `speech-dispatcher`,
#     `pipewire`) go on the wrapper's `LD_LIBRARY_PATH` instead — see the
#     `makeWrapper` call in `installPhase`.
#   * `chrome-sandbox` is dropped: the store cannot hold a setuid bit, and
#     Chromium's unprivileged user-namespace sandbox covers it (nixpkgs
#     defaults `security.allowUserNamespaces = true`).
#   * `resources/app-update.yml` is dropped: electron-updater would
#     dpkg-install an unpatched upstream binary over this store path. The
#     app wraps `checkForUpdates()` in a try/catch, so the missing config
#     is swallowed.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  copyDesktopItems,
  makeDesktopItem,

  # DT_NEEDED by `ai.opencode.desktop` / `chrome_crashpad_handler`.
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libgbm,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  udev,

  # `dlopen()`ed at runtime, not DT_NEEDED — wrapper `LD_LIBRARY_PATH`.
  libglvnd,
  mesa,
  libnotify,
  libpulseaudio,
  libsecret,
  pipewire,
  speechd-minimal,

  # Extra flags appended to the wrapper's argv, e.g.
  # `[ "--ozone-platform-hint=x11" "--disable-gpu" ]`.
  # Appended after the package's own defaults, so they take precedence.
  # Wired to `programs.opencode-desktop.extraArgs`.
  extraArgs ? [ ],
}:
let
  versions = import ../../versions.nix;
  system = stdenv.hostPlatform.system;
  arch = (import ../../lib { inherit lib; }).archOf versions system;

  # Order is irrelevant to the loader but keep-sorted-free on purpose: this
  # list is grouped by why each entry is here, which reads better than
  # alphabetical.
  neededLibs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libgbm
    libxkbcommon
    nspr
    nss
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    pango
    udev
    # libstdc++ for the `pty.node` native addon under `app.asar.unpacked`.
    stdenv.cc.cc.lib
  ];

  dlopenLibs = [
    # ANGLE dlopens `libEGL.so.1` / `libGLESv2.so.2`. Without them Chromium
    # does NOT fall back to the bundled SwiftShader: the GPU process dies
    # and the browser aborts with "GPU process isn't usable. Goodbye."
    libglvnd
    # The GL *driver*. `libglvnd` is only the loader; on NixOS nothing is
    # found through `ld.so.cache` or `/run/current-system/sw/lib`, because
    # every Nix-built binary resolves GL from its own RPATH. A prebuilt
    # Electron bundle with a self-contained RPATH therefore has to carry
    # the driver itself — this is what nixpkgs' own electron gets via
    # `chromium.override`'s buildInputs.
    mesa
    libnotify
    libpulseaudio
    libsecret
    pipewire
    speechd-minimal
  ];

  # Two scaling defects, both verified on an Intel Iris Xe + KWin setup
  # with fractional outputs (1.4x and 1.7x).
  #
  # Under XWayland Chromium never learns the compositor's fractional
  # scale: it renders at 1x and XWayland upscales the result, which looks
  # far too large. `auto` makes Electron talk to the compositor directly
  # when one is offered and fall back to X11 otherwise, so X11-only
  # sessions are unaffected.
  #
  # On native Wayland it binds `wp_fractional_scale_manager_v1` and
  # receives the right `preferred_scale`, but still renders at roughly
  # twice the intended size. Forcing the device scale factor to 1 puts it
  # in step with native KDE apps. Note this pins the scale and ignores
  # the display, so it is uniform across outputs by construction.
  #
  # The remaining three match nixpkgs' from-source build. Letting the app
  # draw its own decorations and speak Wayland text-input natively avoids
  # the XWayland round trip for both.
  defaultFlags = [
    "--ozone-platform-hint=auto"
    "--force-device-scale-factor=1"
    "--enable-features=WaylandWindowDecorations"
    "--enable-wayland-ime=true"
    "--wayland-text-input-version=3"
  ];

  # Appended after `defaultFlags`, so a `--ozone-platform-hint=` supplied
  # here wins: Chromium's switch map keeps the last occurrence.
  flags = defaultFlags ++ extraArgs;

  # `makeShellWrapper`'s `--add-flags` consumes EXACTLY ONE argument and
  # prepends it verbatim to the generated exec line. Per-flag
  # `lib.escapeShellArg` results are therefore joined with spaces and then
  # the whole string is escaped a second time, so it survives as a single
  # shell word whose *content* is the individually-quoted flags.
  extraFlags = lib.escapeShellArg (lib.concatStringsSep " " (map lib.escapeShellArg flags));
in
stdenv.mkDerivation {
  pname = "opencode-desktop";
  inherit (versions) version;

  src = fetchurl {
    url = "https://opencode.ai/files/bin/${versions.version}/opencode-desktop-linux-${arch}.deb";
    hash = versions.systems.${system}.deb;
  };

  strictDeps = true;

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    dpkg
    makeWrapper
  ];

  buildInputs = neededLibs;

  # `src` is a `.deb`, not an unpackable tarball.
  dontUnpack = true;

  desktopItems = [
    (makeDesktopItem {
      name = "ai.opencode.desktop";
      desktopName = "OpenCode";
      comment = "Open source AI coding agent";
      exec = "opencode-desktop %U";
      # Icon name matches the installed `hicolor/*/apps/ai.opencode.desktop.png`
      # and the window's `WM_CLASS`, so the launcher and the taskbar agree.
      icon = "ai.opencode.desktop";
      startupWMClass = "ai.opencode.desktop";
      categories = [ "Development" ];
      mimeTypes = [ "x-scheme-handler/opencode" ];
    })
  ];

  installPhase = ''
    runHook preInstall

    payload=$(mktemp -d)
    dpkg-deb --extract "$src" "$payload"

    mkdir -p $out/libexec/opencode-desktop
    cp -r "$payload"/opt/OpenCode/. $out/libexec/opencode-desktop/

    # SUID chrome-sandbox is impossible in the read-only store; Chromium
    # falls back to its user-namespace sandbox, which nixpkgs enables by
    # default (`security.allowUserNamespaces = true`). Shipping the binary
    # non-setuid would only produce a "sandbox not configured correctly"
    # failure instead of the clean namespace-sandbox path.
    rm -f $out/libexec/opencode-desktop/chrome-sandbox

    # Self-update is disabled by design: the app lives in the immutable Nix
    # store, so electron-updater must never try to install an unpatched
    # upstream binary over it. The app catches update-check failures, so
    # removing the config is a no-op at runtime.
    rm -f $out/libexec/opencode-desktop/resources/app-update.yml

    install -Dm644 \
      "$payload"/usr/share/metainfo/ai.opencode.desktop.metainfo.xml \
      $out/share/metainfo/ai.opencode.desktop.metainfo.xml

    for size in 32 64 128; do
      install -Dm444 \
        "$payload"/usr/share/icons/hicolor/''${size}x''${size}/apps/ai.opencode.desktop.png \
        $out/share/icons/hicolor/''${size}x''${size}/apps/ai.opencode.desktop.png
    done

    # Point GTK at OUR gtk3's module dir rather than the system-wide
    # GTK_PATH from /etc/set-environment. This keeps GTK3 from dlopening
    # modules built against a different GTK major (the system's
    # gtk-3.0/modules ships `colorreload-gtk-module.so`, which is a GTK4
    # module: loading it into GTK3 raises `undefined symbol:
    # gtk_module_display_init`). It silences that symbol error but NOT the
    # resulting "Failed to load module" notices — those come from a theme
    # plugin list naming modules we intentionally do not ship.
    #
    # NB: this comment must stay OUTSIDE the makeWrapper call below. Inside
    # a Nix indented string a hash is literal shell text, and bash rejects a
    # comment in a backslash-continued command -- the line gets parsed as a
    # command and the remaining wrapper flags get executed.
    makeWrapper \
      $out/libexec/opencode-desktop/ai.opencode.desktop \
      $out/bin/opencode-desktop \
      --inherit-argv0 \
      --set GTK_PATH "${gtk3}/lib/gtk-3.0" \
      --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath dlopenLibs} \
      --add-flags ${extraFlags}

    runHook postInstall
  '';

  postFixup = ''
    # Upstream ships `RPATH=$ORIGIN` so `libffmpeg.so` (DT_NEEDED, bundled
    # next to the binary, no version suffix) resolves. `autoPatchelfHook`
    # rewrites that entry; put it back so the bundled codec library is still
    # found. `--add-rpath` appends rather than replacing, and keeps the
    # existing DT_RPATH tag, which — unlike DT_RUNPATH — is also honoured
    # for transitive lookups.
    patchelf --add-rpath '$ORIGIN' $out/libexec/opencode-desktop/ai.opencode.desktop
  '';

  meta = {
    description = "AI coding agent desktop client (Electron)";
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    mainProgram = "opencode-desktop";
    platforms = [ system ];
  };
}

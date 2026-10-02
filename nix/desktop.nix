# Repackages the upstream prebuilt OpenCode Desktop (Electron) app.
#
# Linux: the official .deb is unpacked and its bundled Electron is patched for
#        Nix, so the app always runs on the exact Electron version upstream
#        shipped and tested.
# macOS: the notarized OpenCode.app is installed untouched so its signature
#        stays valid.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  asar,
  autoPatchelfHook,
  copyDesktopItems,
  dpkg,
  makeDesktopItem,
  makeShellWrapper,
  makeWrapper,
  patchelf,
  wrapGAppsHook3,
  ripgrep,

  # Electron runtime libraries (mirrors nixpkgs' electron/binary/generic.nix).
  alsa-lib,
  at-spi2-atk,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  gtk4,
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxkbfile,
  libxrandr,
  libxshmfence,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  speechd-minimal,
  systemd,
  vulkan-loader,

  pname,
  # Entry of sources.json: { version, <system> = { url, hash }; }
  source,
  mainProgram,
  # Desktop entry / icon id used on Linux.
  desktopId,
  # Name shown in launchers, and the macOS bundle name (<desktopName>.app).
  desktopName,
  # Whether this package registers the opencode:// URL scheme on Linux.
  urlSchemeHandler,
  description,
  changelog,
  # Extra arguments for the Electron command line (Linux only).
  commandLineArgs ? "",
}:
let
  inherit (stdenvNoCC.hostPlatform) system isLinux isDarwin;
  artifact = source.${system} or (throw "${pname}: unsupported system ${system}");

  # Name of the Electron executable inside the upstream package.
  executable = "ai.opencode.desktop";
  appDir = "$out/opt/${pname}";

  electronLibs = [
    alsa-lib
    at-spi2-atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    gtk4
    libdrm
    libgbm
    libGL
    libnotify
    libpulseaudio
    libsecret
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxkbfile
    libxrandr
    libxshmfence
    nspr
    nss
    pango
    pciutils
    pipewire
    speechd-minimal
    systemd
    vulkan-loader
    (lib.getLib stdenv.cc.cc)
  ];

  meta = {
    inherit description changelog mainProgram;
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.filter (s: s != "version") (lib.attrNames source);
  };

  linux = {
    nativeBuildInputs = [
      asar
      autoPatchelfHook
      copyDesktopItems
      dpkg
      makeShellWrapper
      patchelf
      wrapGAppsHook3
    ];

    buildInputs = electronLibs;

    unpackPhase = ''
      runHook preUnpack
      dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/opt $out/bin
      cp -r opt/OpenCode ${appDir}

      # Nix manages updates: without its feed config electron-updater can only
      # report a (silent) failed check instead of trying to install a .deb.
      rm -f ${appDir}/resources/app-update.yml ${appDir}/resources/package-type

      # Use nixpkgs' vulkan loader, as nixpkgs' electron does.
      rm -f ${appDir}/libvulkan.so.1
      ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 ${appDir}/libvulkan.so.1

      for size in 32 64 128; do
        install -Dm644 usr/share/icons/hicolor/''${size}x''${size}/apps/ai.opencode.desktop.png \
          $out/share/icons/hicolor/''${size}x''${size}/apps/${desktopId}.png
      done
      asar extract-file ${appDir}/resources/app.asar resources/icons/128x128@2x.png
      asar extract-file ${appDir}/resources/app.asar resources/icons/icon.png
      install -Dm644 128x128@2x.png $out/share/icons/hicolor/256x256/apps/${desktopId}.png
      install -Dm644 icon.png $out/share/icons/hicolor/512x512/apps/${desktopId}.png

      runHook postInstall
    '';

    desktopItems = [
      (makeDesktopItem {
        name = desktopId;
        inherit desktopName;
        comment = description;
        exec = "${mainProgram} %U";
        icon = desktopId;
        # Upstream identifies its windows as ai.opencode.desktop (both v1 and v2).
        startupWMClass = executable;
        categories = [ "Development" ];
        mimeTypes = lib.optional urlSchemeHandler "x-scheme-handler/opencode";
      })
    ];

    # Patching is done explicitly in postFixup so extra RUNPATHs can be added
    # afterwards; the wrapper is created there too.
    dontAutoPatchelf = true;
    dontWrapGApps = true;
    # Stripping corrupts the bun-compiled CLI sidecar shipped by v2.
    dontStrip = true;

    # Musl variants of native node modules are shipped but never loaded.
    autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

    postFixup = ''
      autoPatchelf ${appDir}

      # Chromium dlopens most of its graphics/audio/desktop libraries.
      patchelf --add-rpath ${lib.makeLibraryPath electronLibs} \
        ${appDir}/${executable} ${appDir}/chrome_crashpad_handler
      for lib in ${appDir}/lib*GL*.so; do
        [ -e "$lib" ] || continue
        patchelf --add-rpath ${
          lib.makeLibraryPath [
            libGL
            pciutils
            vulkan-loader
          ]
        } "$lib"
      done

      # A shell wrapper is required for the runtime ''${NIXOS_OZONE_WL:+...}
      # expansion (wrapGAppsHook3 would otherwise select the binary wrapper).
      makeShellWrapper ${appDir}/${executable} $out/bin/${mainProgram} \
        "''${gappsWrapperArgs[@]}" \
        --set OPENCODE_DISABLE_AUTOUPDATE 1 \
        --prefix PATH : ${lib.makeBinPath [ ripgrep ]} \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
        --add-flags ${lib.escapeShellArg commandLineArgs}
    '';
  };

  darwin = {
    nativeBuildInputs = [ makeWrapper ];

    unpackPhase = ''
      runHook preUnpack
      # The archive was created by macOS bsdtar: skip AppleDouble (._*) entries,
      # which would otherwise become extra files that break the bundle seal.
      tar -xzf "$src" --exclude='._*' --warning=no-unknown-keyword
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/Applications $out/bin
      mv OpenCode.app "$out/Applications/${desktopName}.app"
      makeWrapper "$out/Applications/${desktopName}.app/Contents/MacOS/OpenCode" $out/bin/${mainProgram} \
        --set OPENCODE_DISABLE_AUTOUPDATE 1 \
        --prefix PATH : ${lib.makeBinPath [ ripgrep ]}

      runHook postInstall
    '';

    # Any modification would invalidate the notarized signature.
    dontFixup = true;
  };
in
stdenvNoCC.mkDerivation (
  {
    inherit pname meta;
    inherit (source) version;

    src = fetchurl { inherit (artifact) url hash; };

    dontConfigure = true;
    dontBuild = true;

    passthru = { inherit source; };
  }
  // (if isLinux then linux else darwin)
)

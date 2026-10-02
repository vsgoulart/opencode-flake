# Repackages the upstream prebuilt (bun-compiled) OpenCode CLI.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  installShellFiles,
  makeBinaryWrapper,
  unzip,
  ripgrep,
  sysctl,
  wayland,
  versionCheckHook,
  writableTmpDirAsHomeHook,

  pname,
  # Entry of sources.json: { version, <system> = { url, hash }; }
  source,
  mainProgram,
  # How the CLI prints shell completions: "yargs" (v1) or "flag" (v2).
  completionStyle,
  description,
  changelog,
}:
let
  inherit (stdenvNoCC.hostPlatform) system isLinux isDarwin;
  artifact = source.${system} or (throw "${pname}: unsupported system ${system}");
in
stdenvNoCC.mkDerivation {
  inherit pname;
  inherit (source) version;

  src = fetchurl { inherit (artifact) url hash; };
  sourceRoot = ".";

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
  ]
  ++ lib.optional isLinux autoPatchelfHook
  ++ lib.optional isDarwin unzip;

  dontConfigure = true;
  dontBuild = true;
  # Stripping removes the JavaScript payload bun appends to the executable.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 opencode $out/libexec/${pname}/opencode
    makeWrapper $out/libexec/${pname}/opencode $out/bin/${mainProgram} \
      --set OPENCODE_DISABLE_AUTOUPDATE 1 \
      --prefix PATH : ${
        lib.makeBinPath ([ ripgrep ] ++ lib.optional isDarwin sysctl)
      } ${lib.optionalString isLinux "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ wayland ]}"}

    runHook postInstall
  '';

  # Patch right away (instead of during fixup) so the binary can run below.
  dontAutoPatchelf = true;
  postInstall =
    lib.optionalString isLinux ''
      autoPatchelf $out/libexec
    ''
    # opencode uses $TMPDIR/opencode as a directory, which clashes with the
    # extracted binary in the build directory.
    + ''
      rm opencode
    ''
    + lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) (
      ''
        export HOME=$(mktemp -d)
      ''
      + {
        # v1: yargs `completion` command (bash and zsh).
        yargs = ''
          installShellCompletion --cmd ${mainProgram} \
            --bash <($out/bin/${mainProgram} completion) \
            --zsh <(SHELL=/bin/zsh $out/bin/${mainProgram} completion)
        '';
        # v2: `--completions <shell>`. The scripts hardcode the `opencode`
        # command (and `_opencode*` function) names; rebind them to mainProgram.
        flag = ''
          for shell in bash zsh fish; do
            $out/bin/${mainProgram} --completions $shell \
              | sed 's/opencode/${mainProgram}/g' > ${mainProgram}.$shell
          done
          installShellCompletion --cmd ${mainProgram} \
            --bash ${mainProgram}.bash --zsh ${mainProgram}.zsh --fish ${mainProgram}.fish
        '';
      }
      .${completionStyle}
    );

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    versionCheckHook
    writableTmpDirAsHomeHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  passthru = { inherit source; };

  meta = {
    inherit description changelog mainProgram;
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.filter (s: s != "version") (lib.attrNames source);
  };
}

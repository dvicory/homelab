{ inputs, lib, ... }:
let
  # Released security updates awaiting Nixpkgs #586271 and #586269.
  # Drop release overrides once upstream catches up; retain the binary provenance guard.
  releases = {
    "1.26" = {
      version = "1.26.11";
      hash = "sha256-1EEBsP8n7SpMda1GwXucdDWSCeLrLKfJ32y0/baOGWk=";
    };
    "1.27" = {
      version = "1.27.4";
      hash = "sha256-c8+4VxrsDAEXdofbhxY9Rqog6XeWcncokaoXZU2aYJk=";
    };
  };
  secureCompiler =
    pkgs: compiler:
    if lib.versionAtLeast compiler.version releases."1.27".version then
      compiler
    else
      let
        release = releases.${lib.versions.majorMinor compiler.version};
      in
      if lib.versionAtLeast compiler.version release.version then
        compiler
      else
        compiler.overrideAttrs {
          inherit (release) version;
          src = pkgs.fetchurl {
            url = "https://go.dev/dl/go${release.version}.src.tar.gz";
            inherit (release) hash;
          };
        };
  overlay =
    _final: prev:
    let
      go = secureCompiler prev prev.buildPackages.go;
      hoopsnake = inputs.hoopsnake.packages.${prev.stdenv.hostPlatform.system}.hoopsnake;
      hoopsnakeGo = secureCompiler prev hoopsnake.go;
    in
    {
      # ponytail: raw-Go recipes stay upstream; rebind future services that bypass these builders.
      buildGo126Module = prev.buildGo126Module.override {
        go = secureCompiler prev prev.buildPackages.go_1_26;
      };
      buildGo127Module = prev.buildGo127Module.override {
        go = secureCompiler prev prev.buildPackages.go_1_27;
      };
      # Align explicit build inputs and embedded version metadata with the builder.
      k3s = prev.k3s.override { inherit go; };
      docker = prev.docker.override { inherit go; };
      # The independent input package has no .override compiler argument.
      hoopsnake =
        if hoopsnakeGo == hoopsnake.go then
          hoopsnake
        else
          hoopsnake.overrideAttrs (old: {
            nativeBuildInputs = [ hoopsnakeGo ] ++ lib.remove hoopsnake.go old.nativeBuildInputs;
            disallowedReferences = map (
              ref: if ref == hoopsnake.go then hoopsnakeGo else ref
            ) old.disallowedReferences;
            passthru = old.passthru // {
              go = hoopsnakeGo;
            };
          });
    };
in
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system}.extend overlay;
      compiler = secureCompiler pkgs pkgs.hoopsnake.go;
    in
    {
      _module.args.pkgs = pkgs;
      checks.hoopsnake-go-security =
        pkgs.runCommand "hoopsnake-go-security"
          {
            nativeBuildInputs = [
              compiler
              pkgs.jq
            ];
          }
          ''
            go version -m -json ${pkgs.hoopsnake}/bin/hoopsnake |
              jq -e --arg compiler "go${compiler.version}" '
                .GoVersion == $compiler
                and any(.Settings[]; .Key == "CGO_ENABLED" and .Value == "0")
              ' > "$out"
          '';
    };

  den.schema.host.includes = [
    {
      name = "security/go-toolchains";
      os.nixpkgs.overlays = [ overlay ];
    }
  ];
}

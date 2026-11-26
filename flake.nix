{
  description = "mac-toolkit: small macOS utilities behind one menu bar icon, in Zig on nanoui";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      ...
    }:
    let
      lib = nixpkgs.lib;
      # caffeinate and the duck property are macOS's; nixpkgs-unstable dropped
      # x86_64-darwin.
      systems = [ "aarch64-darwin" ];
      forSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # build.zig.zon holds the one version number.
      version = builtins.head (
        builtins.match ".*\\.version = \"([^\"]+)\".*" (builtins.readFile ./build.zig.zon)
      );
      zigFor = pkgs: zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.17.1";
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./build.zig
          ./build.zig.zon
          ./src
          ./macos
          ./tools
          ./LICENSE
        ];
      };
    in
    {
      packages = forSystems (
        pkgs:
        let
          zig = zigFor pkgs;
          # The Zig package tree: nanoui and its lazy dependencies, fetched once.
          # Update the hash when build.zig.zon changes its dependencies.
          deps = pkgs.stdenvNoCC.mkDerivation {
            pname = "mac-toolkit-zig-deps";
            inherit version src;
            nativeBuildInputs = [ zig ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              zig build --fetch=all
            '';
            installPhase = "cp -r zig-pkg $out";
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-pMLHozBddxnXNaGr/KlXxxPimg0p/+wT9o3vdUYX8xg=";
          };
          mac-toolkit = pkgs.stdenvNoCC.mkDerivation {
            pname = "mac-toolkit";
            inherit version src;
            nativeBuildInputs = [
              zig
              pkgs.removeReferencesTo
              pkgs.cctools
              pkgs.darwin.autoSignDarwinBinariesHook
            ];
            dontConfigure = true;
            dontInstall = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              cp -r ${deps} zig-pkg
              chmod -R u+w zig-pkg
              # The build has no xcrun. Zig reads NIX_CFLAGS_COMPILE as its native search
              # paths and takes the SDK's libraries from --search-prefix.
              sdk=${pkgs.apple-sdk.sdkroot}
              export NIX_CFLAGS_COMPILE="-isystem $sdk/usr/include -iframework $sdk/System/Library/Frameworks"
              zig build app install -Doptimize=ReleaseSafe --prefix "$out" --search-prefix "$sdk/usr"
              mkdir -p "$out/Applications"
              mv "$out/mac-toolkit.app" "$out/Applications/"
              # Debug info names Zig's std directory, and the search prefix became an rpath;
              # neither is needed at run time. autoSignDarwinBinariesHook signs them again.
              for f in "$out/bin/mac-toolkit" "$out/Applications/mac-toolkit.app/Contents/MacOS/mac-toolkit"; do
                remove-references-to -t ${zig} "$f"
                install_name_tool -delete_rpath "$sdk/usr/lib" "$f" || true
              done
            '';
            meta = {
              description = "Small macOS utilities behind one menu bar icon";
              mainProgram = "mac-toolkit";
              platforms = systems;
            };
          };
        in
        {
          inherit mac-toolkit;
          default = mac-toolkit;
        }
      );

      apps = forSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };
      });

      checks = forSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        format =
          pkgs.runCommandLocal "mac-toolkit-zig-fmt" { nativeBuildInputs = [ (zigFor pkgs) ]; }
            ''
              zig fmt --check ${src}/build.zig ${src}/src ${src}/tools
              touch "$out"
            '';
      });

      formatter = forSystems (pkgs: pkgs.nixfmt);

      devShells = forSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            (zigFor pkgs)
            # Editor language servers. zls follows Zig's minor version.
            pkgs.zls_0_17
            pkgs.nixd
          ];
          # Zig reads NIX_CFLAGS_COMPILE as a sign to search Nix paths only,
          # and then finds no macOS SDK frameworks.
          shellHook = "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS";
        };
      });
    };
}

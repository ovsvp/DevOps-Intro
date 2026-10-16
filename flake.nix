{
  description = "QuickNotes — reproducible build";

  # Pinned by flake.lock to an exact revision. nixos-25.11 is needed because
  # app/go.mod requires Go >= 1.24 and older channels default to 1.23.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        quicknotes = pkgs.buildGoModule {
          pname = "quicknotes";
          version = "0.1.0";
          src = ./app;

          # No third-party dependencies, so there is no vendor directory to hash.
          # With a populated go.mod this would be the sha256 Nix prints on the
          # first failed build.
          vendorHash = null;

          env.CGO_ENABLED = 0;
          ldflags = [ "-s" "-w" ];

          meta.mainProgram = "quicknotes";
        };

        # Built entirely by Nix -- no Docker daemon involved. dockerTools pins
        # every layer timestamp to the epoch, which is what makes the tarball
        # byte-identical across machines.
        docker = pkgs.dockerTools.buildImage {
          name = "quicknotes-nix";
          tag = "0.1.0";

          copyToRoot = pkgs.buildEnv {
            name = "image-root";
            paths = [ quicknotes ];
            pathsToLink = [ "/bin" ];
          };

          # 65532 is the same nonroot UID the Lab 6 distroless image runs as.
          runAsRoot = ''
            ${pkgs.dockerTools.shadowSetup}
            groupadd -g 65532 nonroot
            useradd -u 65532 -g 65532 -M -s /sbin/nologin nonroot
          '';

          config = {
            Entrypoint = [ "/bin/quicknotes" ];
            ExposedPorts = { "8080/tcp" = { }; };
            User = "65532:65532";
          };
        };

        default = quicknotes;
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.go pkgs.gopls pkgs.golangci-lint ];
        };
      });
    };
}

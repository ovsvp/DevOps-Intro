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
            paths = [
              quicknotes
              # 65532 is the same nonroot UID the Lab 6 distroless image uses.
              # These are plain files rather than a runAsRoot script because
              # runAsRoot boots a VM (vmTools), which needs KVM and so cannot
              # run inside the build containers used to verify reproducibility.
              (pkgs.writeTextDir "etc/passwd"
                "root:x:0:0:root:/root:/sbin/nologin\nnonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin\n")
              (pkgs.writeTextDir "etc/group"
                "root:x:0:\nnonroot:x:65532:\n")
            ];
            pathsToLink = [ "/bin" "/etc" ];
          };

          # The app writes data/notes.json relative to its working directory,
          # so nonroot needs somewhere writable. buildImage has no fakeroot
          # hook (that is buildLayeredImage), and runAsRoot boots a VM via
          # vmTools, which needs KVM and so cannot run inside the containers
          # used to verify reproducibility -- hence mode bits instead of chown.
          # 1777 is the /tmp idiom: writable by the nonroot UID, sticky.
          extraCommands = ''
            mkdir -p app/data
            chmod 1777 app/data
          '';

          config = {
            Entrypoint = [ "/bin/quicknotes" ];
            ExposedPorts = { "8080/tcp" = { }; };
            User = "65532:65532";
            WorkingDir = "/app";
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

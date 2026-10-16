# Lab 11 — Reproducible QuickNotes Builds with Nix

Everything below was run on this repository at branch `feature/lab11`.
"Two independent environments" means two separate `nixos/nix` containers, each
doing its own `git clone` and starting from an empty Nix store.

## Task 1 — Reproducible Go build

### The flake

`flake.lock` is committed next to it and pins nixpkgs to
`b6018f87da91d19d0ab4cf979885689b469cdd41`.

```nix
{
  description = "QuickNotes — reproducible build";

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

          vendorHash = null;

          env.CGO_ENABLED = 0;
          ldflags = [ "-s" "-w" ];

          meta.mainProgram = "quicknotes";
        };
        # ... the `docker` output is shown under Task 2 ...
        default = quicknotes;
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.go pkgs.gopls pkgs.golangci-lint ];
        };
      });
    };
}
```

`nixos-25.11` was chosen because `app/go.mod` requires Go >= 1.24 and the
channel ships Go 1.25.10. `vendorHash = null` is correct here and is *not* a
shortcut — QuickNotes has no third-party dependencies, so `buildGoModule` has
no vendor derivation to hash at all. Setting a string there fails the build.

### Build log excerpt

```
copying path '/nix/store/9y14bfcz45kfvisfqhzim8irxj5bx0bz-go-1.25.10' from 'https://cache.nixos.org'...
copying path '/nix/store/3ndkgg0ijcmydw0ac3q25slzwr9mmlyf-patchelf-0.15.2' from 'https://cache.nixos.org'...
copying path '/nix/store/3ksq0i8va221l9pp8nv606yygjc4dpkf-stdenv-linux' from 'https://cache.nixos.org'...
building '/nix/store/6ynvfxlx0xxnk15lkrr3qk1ba3lid7m6-quicknotes-0.1.0.drv'...
/nix/store/6w3936kcfx0mq99v9z8pkjz53gzkjcv4-quicknotes-0.1.0
```

### Two independent environments, identical store hash

```
среда A: /nix/store/6w3936kcfx0mq99v9z8pkjz53gzkjcv4-quicknotes-0.1.0
среда B: /nix/store/6w3936kcfx0mq99v9z8pkjz53gzkjcv4-quicknotes-0.1.0
```

Same `6w3936kcfx0mq99v9z8pkjz53gzkjcv4` from both.

### The binary runs and answers `/health`

```
$ ./result/bin/quicknotes &
2026/10/16 03:18:37 quicknotes listening on :8080 (notes loaded: 0)

$ curl -s -i http://127.0.0.1:8080/health
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 26

{"notes":0,"status":"ok"}
```

### Design questions

**a) Why does `go build` not produce bit-identical outputs on two machines,
even from the same Git SHA?**

Because the compiler records facts about the machine, not just about the
source. The absolute path of the build directory is baked into the binary
(paths show up in panic traces and in DWARF), so building in `/home/alice/src`
and `/build/src` already diverges. The Go build ID is a hash over the toolchain
and inputs, so a different Go patch release changes it. File modification
times reach the archive metadata, `-ldflags` are often populated from
`git describe` or `date`, and `CGO_ENABLED` defaulting differently (a machine
with a C toolchain vs one without) silently switches to a dynamically linked
binary against that host's libc. Nix removes every one of these: a fixed store
path for the source, one exact pinned compiler, timestamps normalised, and
`CGO_ENABLED = 0` stated explicitly rather than inherited.

**b) `vendorHash` is a SHA over what, exactly? What happens if you set
`vendorHash = null;`?**

It is a fixed-output hash over the *vendor directory* that `buildGoModule`
produces — the result of `go mod download` / `go mod vendor` for the module
graph in `go.mod` plus `go.sum`, serialised as a NAR and hashed. It is the one
derivation in the build that is allowed network access, so the hash is what
makes that access trustworthy: Nix refuses the result if the bytes that came
off the network do not hash to the declared value. Add or bump a dependency and
the hash must change.

`vendorHash = null` tells `buildGoModule` not to create a vendor derivation at
all and to build with `-mod=vendor` off / no module fetching. That is only
valid when the module needs nothing external, which is QuickNotes' case — the
app imports only the standard library. If a dependency were added, the build
would fail outright rather than quietly fetching, which is the safe failure
mode.

**c) `flake.lock` pins nixpkgs. Why is this the single most important file for
reproducibility? What happens if you delete it before the second build?**

`flake.nix` names an input as `github:NixOS/nixpkgs/nixos-25.11` — a *branch*,
which moves. `flake.lock` records the one commit and NAR hash that branch
pointed at when the lock was written. Everything else in the build is derived
from nixpkgs: the Go compiler, stdenv, binutils, the patchelf used on the
output. Pin that one revision and all of it is pinned transitively; leave it
unpinned and the "same" flake silently builds against whatever the channel
advanced to.

Delete it before the second build and `nix build` re-resolves `nixos-25.11` to
its current tip and writes a fresh lock. If the channel moved at all — a Go
point release is enough — the derivation hash changes and the two store paths
differ, so the reproducibility claim collapses even though the Git SHA of the
application is identical. The file is in the commit for exactly this reason.

**d) `buildGoModule` vs `buildGoApplication` — what's the difference? Which
would you pick for QuickNotes and why?**

`buildGoModule` is the nixpkgs builder: it performs the dependency fetch itself
inside one fixed-output derivation guarded by `vendorHash`. The whole module
graph is a single opaque blob to Nix.

`buildGoApplication` comes from gomod2nix: a generator walks `go.mod`/`go.sum`
and emits a `gomod2nix.toml` describing every module individually, so each
dependency becomes its own derivation. That gives per-dependency caching and
granular rebuilds, at the cost of an extra tool, a generated file that must be
regenerated whenever `go.mod` changes, and a third-party flake input.

For QuickNotes `buildGoModule` is the right pick, and not merely by default:
there are zero external dependencies, so the entire advantage of
`buildGoApplication` — granular dependency derivations — buys nothing here,
while its costs (an extra flake input to pin and a generated file to keep in
sync) are real. The dependency-tracking machinery would be managing an empty
set.

## Task 2 — Deterministic OCI image

### The flake extension

```nix
docker = pkgs.dockerTools.buildImage {
  name = "quicknotes-nix";
  tag = "0.1.0";

  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      quicknotes
      (pkgs.writeTextDir "etc/passwd"
        "root:x:0:0:root:/root:/sbin/nologin\nnonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin\n")
      (pkgs.writeTextDir "etc/group"
        "root:x:0:\nnonroot:x:65532:\n")
    ];
    pathsToLink = [ "/bin" "/etc" ];
  };

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
```

Two notes on how this differs from the obvious version:

* The nonroot user is declared with `writeTextDir` files rather than a
  `runAsRoot` script, because `runAsRoot` boots a VM through `vmTools`, which
  needs KVM and therefore cannot run inside the containers used here to verify
  reproducibility.
* The first working image crashed on startup with `seed: mkdir data:
  permission denied` — the app writes `data/notes.json` relative to its working
  directory and UID 65532 owned nothing writable. `buildImage` has no
  `fakeRootCommands` hook (that belongs to `buildLayeredImage`), so the
  directory is created in `extraCommands` with mode 1777, the `/tmp` idiom.

### `docker load` and a running container

```
$ docker load -i result
Loaded image: quicknotes-nix:0.1.0

$ docker run -d --name qn-nix -p 8111:8080 quicknotes-nix:0.1.0
$ docker logs qn-nix
2026/10/16 03:31:12 quicknotes listening on :8080 (notes loaded: 0)

$ curl -s -i http://127.0.0.1:8111/health | head -1
HTTP/1.1 200 OK
$ curl -s http://127.0.0.1:8111/health
{"notes":0,"status":"ok"}

$ curl -s -X POST http://127.0.0.1:8111/notes \
    -H 'Content-Type: application/json' -d '{"title":"nix","body":"reproducible"}'
{"id":1,"title":"nix","body":"reproducible","created_at":"2026-10-16T03:31:14.501645046Z"}
```

### Image size

| image | built by | size |
|---|---|---|
| `quicknotes-nix:0.1.0` | `nix build .#docker` | 8.14 MB |
| `quicknotes:lab6` | `docker build` (distroless, Lab 6) | 13.1 MB |

The Nix image is smaller because it contains the binary, two text files and a
data directory, and nothing else — no distroless base layer with CA
certificates and timezone data.

### Two independent builds, identical digest

```
среда A: 1fa1f2636f5db13779bcc077c8d9e0c2da0b55af8ed5d29835ebec5d0c18527b  result
среда B: 1fa1f2636f5db13779bcc077c8d9e0c2da0b55af8ed5d29835ebec5d0c18527b  result
```

### The Lab 6 image, built twice with `--no-cache`

```
$ docker build --no-cache -t qn-lab6-run1 -f Dockerfile .
$ docker build --no-cache -t qn-lab6-run2 -f Dockerfile .
$ docker images --no-trunc --format '{{.Repository}}  {{.ID}}' | grep qn-lab6
qn-lab6-run2  sha256:2f64eb437edd07004b4661620345e37b9ac0f140cc1e3b0c5ca2e88e89c3e922
qn-lab6-run1  sha256:d629a6aed2b4a337f0b31c313b1f8e6b446678c386e674bed05f217b92239fb7
```

Same Dockerfile, same commit, same machine, minutes apart — different images.

### Design questions

**e) What does `docker build` do that introduces non-determinism, even from the
same Dockerfile + Git SHA?**

It writes the wall clock into the result: every layer and the image config
carry a `created` timestamp, and that alone changes the digest on every build,
which is the dominant effect in the pair above. On top of that, a `FROM
golang:1.25` tag is a moving pointer, so the base can change under an unchanged
Dockerfile; `RUN apt-get install` or `go mod download` reaches the network and
gets whatever upstream serves today; `COPY` preserves mtimes from the build
context; and the build runs as root in a container whose `/tmp` contents, file
ordering from the tar of the context, and environment are not normalised.
Nothing in the format forces the output to be a function of the inputs — the
builder is free to record when and where it ran.

**f) For a security auditor, what can you prove with a reproducible image that
you cannot prove with a signed-but-non-reproducible image?**

A signature proves *provenance*: this artifact came from a holder of that key
and has not been altered since. It says nothing about what went into it. If the
build machine was compromised, or a maintainer slipped an extra line into the
build, the resulting backdoored image is signed just as validly.

Reproducibility proves *correspondence*: the published bytes are what this
source produces, and the auditor can establish that independently, on their own
hardware, without trusting the publisher's machine or key at all. It turns
"trust the signer" into "verify the source", and it makes a compromised build
server detectable — any divergence shows up as a digest mismatch. The two are
complementary rather than competing: the signature tells you who built it, the
reproducibility tells you what they built.

**g) What's the trade-off of Nix's reproducibility? Why is `docker build` still
the default for most teams?**

The cost is the language and the ecosystem boundary. Nix is a lazy functional
language most developers do not know, error messages are notoriously hard to
read (the `fakeRootCommands` mistake in this very lab surfaced as "function
'anonymous lambda' called with unexpected argument"), and anything outside
nixpkgs' idioms — a vendored C library, a proprietary SDK, a build step that
genuinely needs the network — becomes real work. `vendorHash` has to be updated
by hand on every dependency bump. The store grows without bound unless garbage
collection is managed, and CI gains a multi-minute installer step.

`docker build` wins on familiarity: a Dockerfile is a shell script with a
`FROM` line, every engineer can read it, every CI system supports it, and layer
caching makes the inner loop fast. For most teams the artifact being
bit-identical is simply not a requirement — a digest recorded at push time plus
a signature covers their actual threat model. Reproducibility pays off where
the supply chain itself is in scope, and that is a minority of projects.

## Bonus Task — CI-verified reproducibility

### The workflow

`.github/workflows/nix-repro.yml`:

```yaml
name: nix-repro

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  build-a:
    runs-on: ubuntu-latest
    outputs:
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
      - uses: cachix/install-nix-action@448cde739abec1eaf0646249e3d25bb8d9bc7702 # v31.11.2
        with:
          extra_nix_config: experimental-features = nix-command flakes
      - id: build
        run: |
          nix build .#docker
          echo "digest=$(sha256sum result | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"

  build-b:
    runs-on: ubuntu-latest
    outputs:
      digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5
      - uses: cachix/install-nix-action@448cde739abec1eaf0646249e3d25bb8d9bc7702 # v31.11.2
        with:
          extra_nix_config: experimental-features = nix-command flakes
      - id: build
        run: |
          nix build .#docker
          echo "digest=$(sha256sum result | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"

  compare:
    runs-on: ubuntu-latest
    needs: [build-a, build-b]
    steps:
      - name: Compare digests
        env:
          A: ${{ needs.build-a.outputs.digest }}
          B: ${{ needs.build-b.outputs.digest }}
        run: |
          echo "build-a: $A"
          echo "build-b: $B"
          if [ "$A" != "$B" ]; then
            echo "::error::image is not reproducible: digests differ"
            exit 1
          fi
          echo "identical digests, image is reproducible"
```

Both actions are pinned by full commit SHA.

### Green run

https://github.com/ovsvp/DevOps-Intro/actions/runs/38846206932

```
build-a: e3d1bdb70a7066d6086c7cf32e9f18fb2c4a1eb1f18772333b207d59c59364f6
build-b: e3d1bdb70a7066d6086c7cf32e9f18fb2c4a1eb1f18772333b207d59c59364f6
identical digests, image is reproducible
```

This digest is not the same as the `1fa1f263…` recorded under Task 2, and that
is expected rather than a contradiction: the GitHub runners are
`x86_64-linux` while the local containers run `aarch64-linux` on an Apple
Silicon host. A reproducible build is a function of its inputs, and the target
system is one of them. The claim being proven is "same inputs, same output",
not "same output on every architecture".

### Red run

https://github.com/ovsvp/DevOps-Intro/actions/runs/38846501473

`build-b` was given one extra step before building:

```yaml
      - name: DELIBERATE BREAK - let the real build time into the image
        run: sed -i 's|tag = "0.1.0";|tag = "0.1.0"; created = "now";|' flake.nix
```

```
build-a: e3d1bdb70a7066d6086c7cf32e9f18fb2c4a1eb1f18772333b207d59c59364f6
build-b: 77644864068a008932722daa7856d0d8264a6b56f72e3e80e290027e3a8917ea
##[error]image is not reproducible: digests differ
##[error]Process completed with exit code 1.
```

The break was reverted in the following commit and the workflow is green again.

The lab suggests breaking the run with a different `SOURCE_DATE_EPOCH`. That
was tried first and it does **not** work — see question (j) for the measurement
and the reason — so `created = "now"` was used instead, which injects the same
kind of fault (a real timestamp) through the channel that `dockerTools`
actually reads.

### Design questions

**h) What's the difference between "reproducible on my laptop" and
"reproducible in CI" that makes the CI proof load-bearing for a security
auditor?**

A laptop accumulates state, and that state is invisible in the result. The Nix
store already holds the output from the previous build, so the second `nix
build` may simply find the path and print it without compiling anything — which
looks identical to a successful rebuild. There may be a `~/.config/nix/nix.conf`
with extra substituters, an impure environment variable, a local flake registry
override, or an uncommitted file in the working tree. "It matched on my
machine" is therefore a claim about one machine's accumulated history, which
the auditor cannot inspect and cannot re-run.

CI replaces that with two freshly provisioned runners, built from a published
image, that clone only what is committed and start with an empty store. The
logs are public, the workflow that produced them is itself in the repository
and pinned by SHA, and the auditor can re-trigger it. The proof stops being
testimony and becomes an artifact someone else can reproduce — which is the
whole point of the exercise.

**i) Why two parallel jobs instead of one job that runs `nix build` twice?**

Because one job running the build twice mostly tests the Nix cache. The second
invocation computes the same derivation hash, finds the path already in the
local store, and returns it — no compiler runs, and the comparison succeeds
without having rebuilt anything. It would pass even for a wildly
non-deterministic build.

Two jobs get two separate runners with two empty stores, so the artifact is
genuinely produced twice. That also catches the class of non-determinism tied
to the environment rather than to time: a different hostname, a different
number of CPUs affecting parallel build ordering, a different runner image
patch level, a different `$HOME` or build directory path leaking into the
output. A single-job comparison is blind to all of it. Running them in parallel
rather than sequentially additionally rules out ordering effects and keeps the
wall-clock cost of the check to one build.

**j) Where in your Nix flake would the timestamp normally leak in, and how does
`dockerTools.buildImage` handle it?**

The two places a timestamp would enter are the image config's `created` field
and the mtimes of every file in the layer tarball. Both are what make a
`docker build` of the same Dockerfile produce a new digest each time.

`dockerTools.buildImage` closes both. It defaults `created` to the fixed string
`"1970-01-01T00:00:01Z"` rather than the current time, and it assembles the
layer with normalised mtimes and sorted entries so the tar bytes do not depend
on filesystem ordering. Passing `created = "now"` is the documented opt-out,
and it is exactly what the red run above used to break the build.

The specific point about `SOURCE_DATE_EPOCH` is that setting it has **no
effect** here, which was verified rather than assumed:

```
$ docker run --rm -e SOURCE_DATE_EPOCH=1700000000 ... nix build .#docker
SOURCE_DATE_EPOCH на хосте сборки = 1700000000
1fa1f2636f5db13779bcc077c8d9e0c2da0b55af8ed5d29835ebec5d0c18527b  result
# without the variable: 1fa1f2636f5db13779bcc077c8d9e0c2da0b55af8ed5d29835ebec5d0c18527b
```

Two reasons. First, the Nix build sandbox does not pass the host environment
through; it sets `SOURCE_DATE_EPOCH=1` for every builder itself. Second,
`dockerTools.buildImage` does not consult that variable at all — it uses the
hardcoded `created` default. So `SOURCE_DATE_EPOCH` is the canonical knob for
reproducible builds *in general* (autotools, Debian packaging, and other
builders honour it), but in a Nix flake it is already handled one layer down
and is not a lever the flake author pulls.

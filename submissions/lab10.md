# Lab 10 — Cloud Computing: Ship QuickNotes to a Real Cloud

**Author:** Kolpakova Valeriia — v.kolpakova@innopolis.university

**Path:** Option A (Render). The free tier accepted the account without asking for a card, so
the Codespaces fallback was not needed.

---

## Task 1 — CI-Automated Push to `ghcr.io`

### `.github/workflows/release.yml`

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

# Least privilege: the job reads the repo and writes one package, nothing else.
permissions:
  contents: read
  packages: write

jobs:
  publish:
    name: Publish to ghcr.io
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout repository
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0

      - name: Log in to ghcr.io
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f  # v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      # github.repository keeps the owner's casing (ovsvp/DevOps-Intro), but OCI
      # repository names must be lowercase, so the tag has to be folded first.
      - name: Compute image name
        id: image
        run: echo "name=ghcr.io/${GITHUB_REPOSITORY,,}/quicknotes" >> "$GITHUB_OUTPUT"

      - name: Build and push
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc  # v7.4.0
        with:
          context: ./app
          push: true
          # Runners are linux/amd64, which is also what Render runs -- an
          # arm64-only image would build fine here and fail to deploy there.
          platforms: linux/amd64
          tags: |
            ${{ steps.image.outputs.name }}:${{ github.ref_name }}
            ${{ steps.image.outputs.name }}:latest

      # Redeploys Render with the tag just pushed (Task 2 requirement 6).
      - name: Trigger Render deploy
        env:
          HOOK: ${{ secrets.RENDER_DEPLOY_HOOK }}
          IMAGE: ${{ steps.image.outputs.name }}:${{ github.ref_name }}
        run: |
          encoded=$(printf '%s' "$IMAGE" | sed 's|/|%2F|g; s|:|%3A|g')
          curl -fsS "${HOOK}&imgURL=${encoded}" -o /dev/null -w 'render hook: HTTP %{http_code}\n'
```

Two details worth calling out. The **lowercase fold** exists because the first run failed on
exactly this:

```
ERROR: failed to build: invalid tag "ghcr.io/ovsvp/DevOps-Intro/quicknotes:v0.1.0":
repository name must be lowercase
```

`github.repository` preserves the owner's casing, and OCI names cannot. And **`platforms:
linux/amd64`** is deliberate rather than incidental: this laptop is Apple Silicon, so a local
build would produce arm64 and Render — which runs amd64 — could not start it. Pinning the
platform makes the CI artifact right regardless of who triggers it.

### Registry and clean pull

Image: **`ghcr.io/ovsvp/devops-intro/quicknotes`**, tags `v0.1.0` and `latest`.
Green release run: <https://github.com/ovsvp/DevOps-Intro/actions/runs/38087311890>

The package came out **public automatically** — the visibility flip the brief warns about was
not needed. Verified with an anonymous registry token, no credentials involved:

```console
$ T=$(curl -s "https://ghcr.io/token?scope=repository:ovsvp/devops-intro/quicknotes:pull&service=ghcr.io" | jq -r .token)
$ curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $T" \
    https://ghcr.io/v2/ovsvp/devops-intro/quicknotes/manifests/v0.1.0
200
$ # same for :latest
200
```

Then a genuine clean pull. This machine's Docker was logged in to ghcr.io with a token lacking
`read:packages`, and that credential actively *broke* the pull — the registry rejects a bad
credential rather than falling back to anonymous:

```console
$ docker pull ghcr.io/ovsvp/devops-intro/quicknotes:v0.1.0
Error response from daemon: ... denied: denied

$ docker logout ghcr.io
Removing login credentials for ghcr.io

$ docker pull ghcr.io/ovsvp/devops-intro/quicknotes:v0.1.0      # no auth at all
платформа: linux/amd64
пользователь: 65532:65532
точка входа: [/app/quicknotes]
размер: 13.8MB
```

And the pulled image runs:

```console
$ docker run -d -p 28080:8080 -e DATA_PATH=/tmp/n.json -e SEED_PATH=/app/seed.json \
    ghcr.io/ovsvp/devops-intro/quicknotes:v0.1.0
$ curl -s http://localhost:28080/health
{"notes":4,"status":"ok"}
```

### 1.2 — Design questions

**a) OIDC vs `GITHUB_TOKEN` for pushing to ghcr.io**

For this case `GITHUB_TOKEN` with `packages: write` is the right tool and OIDC would be
ceremony: the token is minted per run, scoped to this repository, and expires when the job
ends, so there is no long-lived credential to leak or rotate. It works because ghcr.io and the
repository live inside the same trust domain — GitHub is both the identity provider and the
registry.

OIDC earns its complexity the moment the target is **outside** GitHub: pushing to ECR, GAR or
Docker Hub, or deploying to AWS/GCP. The alternative there is a static cloud credential stored
as a repository secret — a long-lived key that works from anywhere, forever, for whoever
obtains it. OIDC replaces it with a short-lived token the cloud issues after verifying a signed
claim about *which repository, which branch and which workflow* is asking. Nothing persistent
is stored, and the cloud's trust policy can be narrowed to "only the `main` branch of this one
repo", which a static secret cannot express.

**b) Why ship `:latest` alongside an immutable `:v0.1.0`?**

Because they answer different questions. `:v0.1.0` is the one you *deploy*: it names exactly
one artifact forever, so a rollback is unambiguous, an incident timeline can state what was
running, and a scan result stays attached to a specific thing. Render points at the immutable
tag for exactly that reason.

`:latest` is a convenience pointer for humans and for the cases where "newest" is genuinely
what you mean — someone trying the project, a smoke test, a docs example that should not go
stale every release. It is also what most registries show by default, so omitting it makes the
package look empty to anyone browsing.

The rule that keeps both honest is that `:latest` is for convenience and never for production:
anything that must be reproducible references the digest or the immutable tag.

**c) `packages: write` only — the principle and the concrete attack**

The principle is least privilege: the token should be able to do the job and nothing else. The
default permission set, or `write: all`, gives the same auto-generated token the ability to
push commits, move tags, open and merge pull requests, edit issues, and create releases.

The concrete attack is a compromised step. This workflow runs third-party actions —
`docker/login-action`, `docker/build-push-action` — plus whatever they pull in. If one of them
were backdoored (the tj-actions pattern from Lab 3), the malicious code runs with whatever
`GITHUB_TOKEN` can do. With `packages: write` the worst case is a bad image in the registry:
visible, revertible, and scoped to one package. With `contents: write` the same compromise can
push a commit to `main` — persisting the attacker's code in the repository itself, which then
gets built into every future image and may survive long after the bad action is removed.
Narrowing the scope converts a foothold into an inconvenience.

---

## Task 2 — Deploy to Render

**Option A, Render.** The signup asked for nothing but a GitHub login; no card verification
screen appeared, so the Codespaces fallback was unnecessary.

Configuration is recorded in [`cloud/render.md`](../cloud/render.md): Free instance, source
**Existing Image** `ghcr.io/ovsvp/devops-intro/quicknotes:v0.1.0`, health check path `/health`,
and four environment variables.

### The service is live

Public URL: **<https://quicknotes-v0-1-0-zyuh.onrender.com>**

```console
$ curl -s https://quicknotes-v0-1-0-zyuh.onrender.com/health
{"notes":4,"status":"ok"}

$ curl -s https://quicknotes-v0-1-0-zyuh.onrender.com/notes
[{"id":1,"title":"Welcome to QuickNotes","body":"This is the project you'll containerize,
deploy, monitor, and harden across all 10 labs.","created_at":"2026-01-15T10:00:00Z"},
{"id":2,"title":"Read app/main.go first", …
```

### The port agreed on the first boot

```
==> Starting service...
==> Setting WEB_CONCURRENCY=1 by default, based on available CPUs in the instance
2026/10/11 00:59:06 quicknotes listening on :8080 (notes loaded: 4)
==> Your service is live 🎉
==> Available at your primary URL https://quicknotes-v0-1-0-zyuh.onrender.com
```

No `New primary port detected … Restarting deploy` line — because `PORT=8080` and `ADDR=:8080`
were set before the first deploy rather than discovered after it.

### Deploying from CI, verified end to end

Pushing a second tag exercised the whole chain — build, push, redeploy — with no manual step:

```console
$ git tag -a -s v0.1.1 -m "Lab 10: verify the deploy hook redeploys Render"
$ git push origin v0.1.1
```

From the release run's log (<https://github.com/ovsvp/DevOps-Intro/actions/runs/38102529972>):

```
Trigger Render deploy
  IMAGE: ghcr.io/ovsvp/devops-intro/quicknotes:v0.1.1
render hook: HTTP 200
```

and the service answered afterwards:

```console
$ curl -s https://quicknotes-v0-1-0-zyuh.onrender.com/health
{"notes":4,"status":"ok"}
```

The hook URL never appears in the repository — it is read from the `RENDER_DEPLOY_HOOK` Actions
secret, and the tag is passed as a URL-encoded `imgURL` so Render pulls the version that was
just published rather than the one the service was created with.

### 2.2 — Warm and cold latency

**Warm** — five consecutive requests with the service already awake:

```console
запрос 1: 0.279622s   запрос 2: 0.292648s   запрос 3: 0.269282s
запрос 4: 0.286572s   запрос 5: 0.288134s
```

**p50 = 286 ms.**

**Cold** — the service spins down after 15 minutes without traffic; each measurement below
follows a fresh idle period of 17-18 minutes.

| # | Idle before the request | Cold start |
|---|---|---:|
| 1 | 17 min | **12.52 s** |
| 2 | 18 min | **11.87 s** |
| 3 | 18 min | **12.19 s** |

**Median 12.19 s — roughly 43× the warm p50.** The spread is under a second across three
samples, which says the wake path is a predictable sequence of work (schedule, unpack, start,
health-check) rather than contention for capacity; a queueing effect would show much more
variance.

One measurement artefact worth recording, because it wasted a sample: a fourth attempt returned
`0.62 s`. That was not a fast cold start — it was a warm hit. The 15-minute timer restarts on
*every* request, so an earlier probe (or a browser tab left open on the service URL) resets it.
A cold measurement is only valid if nothing has touched the service for the full window, which
is easy to break without noticing.

### Step 5 — what happened to the note

Before the first spin-down I created a note and confirmed the service held five:

```console
$ curl -X POST -d '{"title":"before-spindown","body":"written at 01:07:15Z"}' …/notes
{"id":5,"title":"before-spindown","body":"written at 01:07:15Z","created_at":"2026-10-11T01:07:16Z"}
$ curl -s …/health
{"notes":5,"status":"ok"}
```

After the spin-down and wake:

```console
$ curl -s …/notes | …
всего заметок: 4
before-spindown: ИСЧЕЗЛА
заголовки: Welcome to QuickNotes, Read app/main.go first, DevOps mantra, Endpoint cheat-sheet
```

**The note is gone and the store is back to the four seeded records.** Explained under
question f.

### 2.4 — Design questions

**d) Render spin-down vs Cloud Run scale-to-zero**

Same idea, two orders of magnitude apart: my measured cold start is ~12 s against Cloud Run's
typical few hundred milliseconds.

The difference is what has to be rebuilt. Render's free tier genuinely stops the service — the
container is gone, and a request arriving at a sleeping service has to wait for a scheduler to
find capacity, pull or unpack the image onto a host, start the container, and wait for the
health check to pass before any traffic is routed. Cloud Run keeps a much hotter path: the
image is already distributed across the fleet in a streamable format, the sandbox
(gVisor/microVM) is designed to boot in milliseconds, and the platform keeps the request
queued at the front door while that happens.

They optimise for different things. Cloud Run optimises for *request-driven production
traffic*, where a cold start is a user-visible latency event, and charges per request and per
CPU-second to pay for that machinery. Render's free tier optimises for *cost of idle capacity*:
it is giving away hosting, so reclaiming the resources of an idle service completely is the
whole point, and a 12-second wake is an acceptable price for something nobody is paying for.
Render's own paid tiers do not spin down at all — which shows the behaviour is a pricing
decision rather than a technical limit.

**e) Why does Render inject `PORT` instead of reading `EXPOSE`?**

Because `EXPOSE` is documentation, not configuration. It is a metadata field in the image that
records the author's intent; it binds nothing, and Docker itself ignores it unless you ask for
`-P`. A platform that routed traffic based on `EXPOSE` would be trusting a label that may be
absent, wrong, or list several ports with no way to say which one matters.

`PORT` inverts the relationship: the platform decides and the application obeys, which is the
only arrangement that works when the platform must allocate ports across many tenants. It is
the Twelve-Factor "port binding" rule, and it is why nearly every PaaS does the same thing.

I set **`PORT=8080`** (tell Render to route there) and **`ADDR=:8080`** (tell QuickNotes to
listen there), plus `DATA_PATH=/data/notes.json` and `SEED_PATH=/app/seed.json` for the
filesystem side. Fixing it in configuration rather than in code is what the brief asks for, and
it is also the better engineering: QuickNotes stays a plain Go binary that reads its address
from an env var, with no knowledge that Render exists.

The cost of getting this wrong is visible in the deploy log. Render starts the container, finds
nothing listening on the port it expected, detects the real one, logs `New primary port
detected`, and **restarts the deploy** — roughly 45 extra seconds, on every single deploy,
forever, until someone fixes the variables. It still goes live, which is exactly why it is easy
to leave broken.

**f) Existing image vs letting Render build — and where the note went**

Pointing Render at **the existing image** means the artifact serving traffic is bit-for-bit the
one CI built, Lab 9 scanned, and I pulled anonymously to verify. That chain of custody is the
main argument: a rebuild on Render's side could resolve a base image to a different digest or
pick up a different builder, and the scan result would no longer describe what is running.
Deploys are also faster, since there is no build at all — Render just pulls.

Building from the repo buys convenience instead: no registry to manage, no tag to remember, and
a push-to-deploy loop for people who are not running CI. It costs reproducibility and build
caching, and it duplicates work CI already does. For this project, where Lab 3 already builds
and Lab 9 already scans, the registry is the better source.

**Where the note went:** nowhere — it was never persisted anywhere durable. Render's free tier
gives the container an **ephemeral filesystem**. `DATA_PATH=/data/notes.json` points inside the
container, and on spin-down that container is destroyed, not paused. Waking the service creates
a *new* container from the same image, whose `/data` is empty, so `ensureSeeded` finds no data
file and re-seeds from `/app/seed.json` — which is exactly the four records I observed. Keeping
the note would require a Render persistent disk (not available on the free tier) or an external
store such as a managed database, which is the normal answer for stateful services on
scale-to-zero platforms.

---

## Bonus Task — Cloudflare Tunnel

**Not completed: this network blocks Cloudflare Tunnel.** The local half works — the same
`ghcr.io` image runs on port 8099 and answers `{"notes":4,"status":"ok"}` — but `cloudflared`
cannot establish a tunnel from here. Three attempts, each failing one layer deeper:

**1. `cloudflared` on the host.** The tunnel exits immediately at edge discovery:

```
ERR edge discovery: error looking up Cloudflare edge IPs: the DNS query failed
    error="lookup _v2-origintunneld._tcp.argotunnel.com on 1.2.3.4:53: server misbehaving"
ERR Initiating shutdown error="Could not lookup srv records on _v2-origintunneld._tcp.argotunnel.com"
```

The system resolver is `1.2.3.4`, which does not answer SRV queries correctly. The published
`trycloudflare.com` URL therefore returns Cloudflare **error 1033** — "Cloudflare is currently
unable to resolve it" — which is the edge saying no tunnel ever connected.

**2. In a container with a known-good resolver** (`--dns 1.1.1.1`): the same SRV failure. So it
is not the local resolver choice — SRV responses are being interfered with on the path. (Lab 4
turned up the same signature: `dig +short localhost` returned `198.18.212.211`, an address from
the RFC 2544 benchmark range, with the authoritative flag set.)

**3. Bypassing DNS entirely.** A records *do* resolve, so I looked the edge up directly and
passed the addresses to `cloudflared`, skipping SRV discovery:

```console
$ dig +short region1.v2.argotunnel.com
198.41.192.47  198.41.192.227

$ cloudflared tunnel --edge 198.41.192.47:7844 --edge 198.41.200.63:7844 --url …
INF precheck component="UDP Connectivity" details="QUIC connection failed"  status=fail target=198.41.192.47:7844
INF precheck component="TCP Connectivity" details="HTTP/2 connection is blocked or unreachable" status=fail target=198.41.192.47:7844
```

That is the answer: **port 7844 is blocked outbound, over both TCP and UDP**, to every edge
address. No `cloudflared` configuration can work around a filtered port, so the comparison
table and questions g-i are not attempted. The alternative public-URL route the brief mentions,
ngrok, needs an account and authtoken, which I did not create.

---

## Teardown

[`cloud/render.md`](../cloud/render.md) records how to remove the service. Free instance hours
cost nothing, so it is left running for grading; the deploy hook should be regenerated
afterwards, since its URL embeds a key.

# Lab 9 — DevSecOps: Scan QuickNotes with Trivy + ZAP

**Author:** Kolpakova Valeriia — v.kolpakova@innopolis.university

**Two pinning deviations, both forced and both stated here rather than hidden.** The brief
suggests `ghcr.io/zaproxy/zaproxy:2.16.x`; this machine's Docker is logged in to `ghcr.io` with
a personal token, and GHCR refuses third-party public pulls when a non-matching credential is
presented. Rather than log the account out, I used the same project's Docker Hub image,
pinned: **`zaproxy/zap-stable:2.17.0`**. Trivy is pinned to **`aquasec/trivy:0.59.1`** as asked.

---

## Task 1 — Trivy: Image + Filesystem + Config + SBOM

All four scans are committed under [`security/`](../security/).

### 1. Image scan

```console
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:0.59.1 image --severity HIGH,CRITICAL --no-progress quicknotes:lab6

quicknotes:lab6 (debian 13.7)
Total: 0 (HIGH: 0, CRITICAL: 0)

app/healthcheck (gobinary)
Total: 21 (HIGH: 21, CRITICAL: 0)

app/quicknotes (gobinary)
Total: 21 (HIGH: 21, CRITICAL: 0)
```

Full output: [`security/trivy-image.txt`](../security/trivy-image.txt)

### 2. Filesystem scan

```console
$ docker run --rm -v "$PWD":/repo aquasec/trivy:0.59.1 fs --severity HIGH,CRITICAL --no-progress /repo

.vagrant/machines/default/virtualbox/private_key (secrets)
Total: 1 (HIGH: 1, CRITICAL: 0)

HIGH: AsymmetricPrivateKey (private-key)
 .vagrant/machines/default/virtualbox/private_key:1
   1 [ BEGIN OPENSSH PRIVATE KEY-----****…****-----END OPENSSH PRI
```

Full output: [`security/trivy-fs.txt`](../security/trivy-fs.txt)

### 3. Config scan

```console
$ docker run --rm -v "$PWD":/repo aquasec/trivy:0.59.1 config /repo

app/Dockerfile (dockerfile)
Tests: 28 (SUCCESSES: 26, FAILURES: 2)
Failures: 2 (UNKNOWN: 0, LOW: 1, MEDIUM: 1, HIGH: 0, CRITICAL: 0)

AVD-DS-0013 (MEDIUM): RUN should not be used to change directory: 'cd /hc && go mod init …'.
                      Use 'WORKDIR' statement instead.
AVD-DS-0026 (LOW):    Add HEALTHCHECK instruction in your Dockerfile
```

Full output: [`security/trivy-config.txt`](../security/trivy-config.txt)

(`--no-progress` is not a valid flag for `trivy config` in 0.59.1 — it exits with
`unknown flag`. The scan above is the corrected invocation.)

### 4. CycloneDX SBOM

```console
$ docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD/security":/out \
    aquasec/trivy:0.59.1 image --format cyclonedx --output /out/sbom-cyclonedx.json quicknotes:lab6
```

CycloneDX 1.6, **13 components**, 17 KB: [`security/sbom-cyclonedx.json`](../security/sbom-cyclonedx.json).
First 30 lines:

```json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "serialNumber": "urn:uuid:8d244762-1ae7-422f-ae4a-88620fb7bc51",
  "version": 1,
  "metadata": {
    "timestamp": "2026-10-09T17:33:17+00:00",
    "tools": {
      "components": [
        {
          "type": "application",
          "group": "aquasecurity",
          "name": "trivy",
          "version": "0.59.1"
        }
      ]
    },
    "component": {
      "bom-ref": "1363a08a-ff0f-4150-9fca-abb5fe9b39e3",
      "type": "container",
      "name": "quicknotes:lab6",
      "properties": [
        {
          "name": "aquasecurity:trivy:DiffID",
          "value": "sha256:187cfc6d1e3e8a40a5e64653bcd3239c140807dcf1c09e48021178705a5a6139"
        },
        {
          "name": "aquasecurity:trivy:DiffID",
          "value": "sha256:275a30dd8ce958b21daa9ad962c6fbc09f98306ee2f486b65c9075dc257b1412"
```

(Note the command: `trivy sbom` in 0.59.1 *consumes* an SBOM; generating one is
`trivy image --format cyclonedx`.)

### 1.2 — Triage: every HIGH/CRITICAL with a disposition

The 21 image findings are **the same 21 CVEs in both binaries** — every one is `stdlib`, none
is a third-party module, because `app/go.mod` has no `require` block. They are therefore one
decision, not 42.

| # | Finding | Where | Severity | Disposition | Reason |
|---|---|---|---|---|---|
| 1 | 21 × `stdlib` CVEs in Go 1.24.13 — `CVE-2026-25679`, `-27145`, `-32280`, `-32281`, `-32283`, `-33811`, `-33814`, `-33818`, `-39820`, `-39821`, `-39822`, `-39836`, `-42499`, `-42504`, `-56853`, `-56858`, `-56859`, `-56860`, `-56862`, `-78667`, `-97031` | `app/quicknotes`, `app/healthcheck` | HIGH ×21 | **FIX** (blocked) | Fixed versions are 1.25.8 → 1.26.9; **no 1.24.x fix exists**, because Go backports security patches only to the two most recent majors and 1.24 has aged out. The fix is to move the builder to Go 1.25.11+. I did not apply it here because Lab 6 Task 1.1 requires the builder pinned to **1.24** and Lab 9 scans that image — changing it would break the artifact under test. **Re-evaluate: on the next lab that is free to choose its toolchain, or by 2026-12-31, whichever is sooner.** `govulncheck` (bonus) confirms these are not theoretical: 19 of them are *reachable* from QuickNotes' own call graph. |
| 2 | `AsymmetricPrivateKey` — OpenSSH private key | `.vagrant/machines/default/virtualbox/private_key` | HIGH | **FALSE POSITIVE** | Correct detection, wrong conclusion. This is the throwaway keypair Vagrant generates per VM; `.vagrant/` is in the repo's `.gitignore`, so it is on my disk and never in git history (verified: `git log --all -- '.vagrant/**'` is empty). It grants access to one local VM that is rebuilt from a `Vagrantfile`, and `vagrant destroy` invalidates it. The scanner cannot see any of that — it sees PEM headers, which is exactly what it should flag. |
| 3 | `AVD-DS-0013` — `RUN cd …` instead of `WORKDIR` | `app/Dockerfile` | MEDIUM | **ACCEPT** | Below the HIGH/CRITICAL bar the brief sets, recorded for completeness. The `cd /hc` is inside the *builder* stage building the healthcheck probe in a scratch directory; it never reaches the runtime image. Rewriting it as `WORKDIR` would add a stage-local directive for a lint score, not for safety. **Re-evaluate: 2027-04-01.** |
| 4 | `AVD-DS-0026` — no `HEALTHCHECK` in the Dockerfile | `app/Dockerfile` | LOW | **ACCEPT** | The healthcheck exists, in `compose.yaml` (Lab 6 Task 2.1), which is how this image is actually run; the probe binary is baked into the image for exactly that. A Dockerfile `HEALTHCHECK` would duplicate it, and Compose's definition wins where they disagree. **Re-evaluate: 2027-04-01, or sooner if the image starts being run outside Compose.** |

### 1.3 — Design questions

**a) CVE severity is one input. What else matters?**

**Reachability**, first. A CVE in a function nothing calls is a number in a report; one on a
hot path is an incident waiting to happen. This lab produced the clean illustration: Trivy says
the binary *contains* Go 1.24.13's vulnerable stdlib (21 findings, module presence);
`govulncheck` says QuickNotes *actually calls into* 19 of them, with traces like
`main.go:37:31 → http.Server.ListenAndServe → url.ParseRequestURI`. Same artifact, two very
different triage workloads.

**Exploit availability and maturity.** A CVE with a public PoC and an entry in CISA's KEV
catalogue is a different urgency than one with a theoretical write-up, regardless of CVSS.

**Deployment context**, which is usually what collapses the list. QuickNotes runs distroless
as UID 65532, with all capabilities dropped and a read-only root filesystem (Lab 6 bonus) — a
CVE whose impact is "local privilege escalation via setuid" has nowhere to go here. Whether the
affected surface is even exposed matters just as much: a TLS parsing CVE is severe for an
internet-facing listener and near-irrelevant for a binary that only ever serves plaintext HTTP
behind a proxy.

And **data sensitivity**: the same RCE is a different incident in a notes demo than in a
payroll system.

**b) Why is the minimal base the strongest single security control?**

Because it removes the vulnerabilities instead of managing them. My image scan is the evidence:
the distroless base contributes **0 HIGH/CRITICAL across 6 packages**, where a `debian:13-slim`
base would carry roughly a hundred packages — every one of which can get a CVE, demand triage
time, and force a rebuild for a component QuickNotes never calls.

The second-order effect is larger than the CVE count. No shell, no package manager, no
coreutils means a whole class of post-exploitation technique has nothing to run: an attacker
who achieves code execution cannot `curl | sh`, cannot `apt install`, cannot spawn `/bin/sh`.
Most exploit chains assume those exist.

It is also the control that *keeps* working without effort. Patching requires someone to notice
and act; "the package is not installed" requires nobody to do anything, ever.

**c) When is `.trivyignore` right, and when is it theatre?**

It is right when the finding is genuinely not applicable and you can say why in one sentence —
a CVE in a code path your build does not compile, a vulnerability in a dev-only dependency
absent from the runtime image, or finding #2 in my table above (a gitignored throwaway VM key).
In those cases the entry removes noise that would otherwise erode attention, and it belongs in
version control with a comment and a date so the reasoning outlives the person who wrote it.

It is theatre the moment it is used to make the build green. Suppressing a reachable CVE
because the upgrade is inconvenient converts a visible problem into an invisible one, and the
build going green actively communicates the opposite of the truth to everyone who looks at it.
The tell is an entry with no comment, no date, and no owner — which in practice is permanent,
because nobody will ever audit a file whose purpose is to be ignored.

My own stdlib findings (row 1) are exactly where this temptation lives. I left them failing.

**d) What future problem does today's SBOM solve?**

It answers "are we affected?" in minutes instead of weeks. During Log4Shell in December 2021
the hard part was not patching Log4j — it was that most organisations could not *enumerate*
where Log4j was, because it arrives as a transitive dependency of something else. Teams spent
days grepping build files across repos while the exploit was already being used.

An SBOM inverts that: when the next CVE lands against component X, you query a list you already
have. My `sbom-cyclonedx.json` records all 13 components of this image with versions and
purls — a machine-readable answer available before the question is asked, which is the only
time it is cheap to produce.

The secondary use is supply-chain provenance: the SBOM records what went in, so you can detect
when a build starts including something nobody added deliberately.

---

## Task 2 — OWASP ZAP Baseline + Fix

### Running the baseline

QuickNotes and ZAP shared a Docker network so ZAP could reach the container by name — the
equivalent of the brief's `http://localhost:8080` when both sides are containers:

```console
$ docker network create zapnet
$ docker run -d --name qn-zap --network zapnet \
    -e DATA_PATH=/tmp/notes.json -e SEED_PATH=/app/seed.json quicknotes:lab6

$ docker run --rm --network zapnet -v "$PWD/security":/zap/wrk:rw -u root \
    zaproxy/zap-stable:2.17.0 zap-baseline.py \
    -t http://qn-zap:8080 -J zap-before.json -r zap-before.html
```

Reports: [`security/zap-before.html`](../security/zap-before.html) ·
[`security/zap-before.json`](../security/zap-before.json)

### 2.2 — Triage: every finding

```
FAIL-NEW: 0   FAIL-INPROG: 0   WARN-NEW: 1   WARN-INPROG: 0   INFO: 0   IGNORE: 0   PASS: 66
```

| ID | Name | Risk | Affected URLs | Disposition | Reason |
|---|---|---|---|---|---|
| 10049 | Storable and Cacheable Content | Informational (confidence Medium) | `/`, `/robots.txt`, `/sitemap.xml` (3 instances) | **FIX** | Fixed in commit `6ca99fd` by adding `Cache-Control: no-store` in the new middleware. Notes are per-user data; nothing in QuickNotes should ever be stored by a shared cache and replayed to a different caller. Low effort, real benefit, no downside for an API that has no cacheable static content. Verified gone in the re-scan below. |

That is the complete list — ZAP reported one warning and passed 66 other rules.

**The brief expects missing security headers here, and ZAP did not report them. That is worth
explaining rather than glossing over.** ZAP's passive rules for CSP (10038), anti-clickjacking
(10020) and `X-Content-Type-Options` (10021) only evaluate responses the browser would render
as a document — they key off HTML content types. QuickNotes answers
`Content-Type: application/json` on every route, so those rules do not fire, and ZAP counts
them as PASS. I confirmed the headers were genuinely absent before the fix:

```console
$ curl -D - -o /dev/null http://qn-zap:8080/health      # pre-fix image
HTTP/1.1 200 OK
Content-Type: application/json
Date: Fri, 09 Oct 2026 16:45:27 GMT
Content-Length: 26
```

No CSP, no `X-Content-Type-Options`, no `X-Frame-Options` — ZAP simply had no rule that cared.
So I fixed both: the finding ZAP actually reported (`Cache-Control`), **and** the headers the
brief points at, as defence in depth. Only the first one can be proven gone by a re-scan; the
others are proven by the unit test and by `curl`.

### 2.3 — The fix

`app/handlers.go` — one middleware wrapping the whole router, so a route added later cannot
ship without the headers:

```go
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.wrap(s.handleHealth))
	// … all other routes unchanged …
	return securityHeaders(mux)
}

// securityHeaders sets the response headers OWASP ZAP's baseline scan reports as
// missing. It wraps the whole router rather than each handler, so a route added
// later cannot ship without them.
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// QuickNotes is a JSON API: it loads no scripts, styles, images or fonts,
		// so the strictest possible policy costs nothing here.
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		// Addresses ZAP 10049: notes are per-user data, so no shared cache should
		// ever store a response and replay it to somebody else.
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
```

The signature change from `*http.ServeMux` to `http.Handler` is what makes wrapping possible;
both call sites (`main.go`, `handlers_test.go`) already used it as a `Handler`.

`app/security_headers_test.go` asserts all five headers across five routes — including
`/does-not-exist`, so the 404 path is covered too:

```go
func TestSecurityHeaders_PresentOnEveryRoute(t *testing.T) {
	want := map[string]string{
		"Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
		"X-Content-Type-Options":  "nosniff",
		"X-Frame-Options":         "DENY",
		"Referrer-Policy":         "no-referrer",
		"Cache-Control":           "no-store",
	}
	// … five routes, every header checked on each …
}
```

**The test genuinely guards the fix.** Removing `securityHeaders(mux)` from `Routes()` makes it
fail — I verified it rather than assuming:

```console
    security_headers_test.go:37: Content-Security-Policy: got "", want "default-src 'none'; frame-ancestors 'none'"
    security_headers_test.go:37: X-Frame-Options: got "", want "DENY"
    security_headers_test.go:37: Referrer-Policy: got "", want "no-referrer"
FAIL	quicknotes	0.004s
```

### 2.4 — Re-scan proves the finding is gone

Rebuilt as `quicknotes:lab9` and re-ran the identical baseline:

```console
$ curl -D - -o /dev/null http://qn-zap-after:8080/health
HTTP/1.1 200 OK
Content-Security-Policy: default-src 'none'; frame-ancestors 'none'
Content-Type: application/json
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Cache-Control: no-store
```

| | Before | After |
|---|---|---|
| Alert 10049 | **Storable and Cacheable Content** — Informational, 3 instances | **Non-Storable Content** — Informational, 2 instances |
| Totals | `WARN-NEW: 1  PASS: 66` | `WARN-NEW: 1  PASS: 66` |

The alert I fixed is gone. What replaced it is the same plugin's *opposite* verdict: 10049
reports either "Storable and Cacheable" or "Non-Storable" depending on what it observes, and
after the fix it observes non-storable. The warning count staying at 1 is therefore not a
failure to fix anything — it is the same rule reporting the desired state.

Reports: [`security/zap-after.html`](../security/zap-after.html) ·
[`security/zap-after.json`](../security/zap-after.json)

### 2.5 — Design questions

**e) Why middleware instead of per-handler header sets?**

Because per-handler is a policy that depends on every future author remembering it. QuickNotes
has six routes today; the seventh gets added by someone who copies an existing handler, and if
that handler is the one they copied *before* the headers were added, the new route silently
ships without them — and nothing fails. Security that degrades as the codebase grows is not a
control, it is a hope.

Middleware makes the headers a property of the *router* rather than of each handler, so the
default flips: a new route is protected unless someone deliberately bypasses the wrapper. It
also gives exactly one place to change the policy, one place to read it during review, and one
thing for a test to assert. My test checks `/does-not-exist` precisely because that response is
produced by `ServeMux` itself, with no handler of mine involved — a per-handler approach could
not cover it at all.

**f) What does `default-src 'none'` break, and why is it fine here but not for a website?**

It blocks everything a document could load: scripts, stylesheets, images, fonts, frames, media,
XHR/fetch. Nothing with a `src` or `href` to a subresource will load.

For QuickNotes that costs nothing, because there is no document. Every response is
`application/json` consumed by an HTTP client — `curl`, `fetch` from some other origin's page,
Prometheus. A JSON body does not load subresources, so a policy forbidding subresources forbids
nothing that happens. If someone ever tricks a browser into rendering a response as HTML, the
CSP is what stops injected content from calling home — which is the whole point of setting it
on an API.

On a website it would break the site on the first page load: no CSS, no JS, no images, no web
fonts. A real site needs an allowlist built from what it actually uses (`script-src 'self'` plus
specific CDNs, `img-src 'self' data:`, and so on), which is substantially more work to get
right and to keep right as the frontend changes. The brief's own pitfall is the concrete
version of this: add Swagger UI to QuickNotes later and `default-src 'none'` breaks it, because
Swagger UI *is* a document with subresources.

**g) What does marking informational findings "accepted" without reading them cost?**

It costs the ability to notice the one that matters. Rubber-stamping trains you to treat the
whole category as noise, and the next scan's new informational finding gets the same reflex —
but informational is a statement about *confidence and context*, not about impact. ZAP cannot
know that the cacheable response it found contains other people's notes; that is exactly the
judgement a human is there to supply. My single finding was Informational, and it was worth
fixing.

There is a second cost, in the record rather than the system. An "accepted" with no reasoning
is indistinguishable six months later from an acceptance that was carefully considered, so the
next person either re-does the analysis from scratch or trusts a decision nobody actually made.
That is why every acceptance in this report carries a reason and a re-evaluation date — an
acceptance without a date is a permanent decision disguised as a temporary one.

---

## Bonus Task — `govulncheck` as a CI PR Gate

### The job

Added to the Lab 3 workflow, with `ci-ok` extended to depend on it so a failure genuinely
blocks the PR (`needs: [vet, test, lint, govulncheck]`):

```yaml
  govulncheck:
    name: Govulncheck
    runs-on: ubuntu-24.04
    defaults:
      run:
        working-directory: app
    steps:
      - name: Checkout repository
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0

      - name: Set up Go
        uses: actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff  # v5.6.0
        with:
          go-version: '1.24'
          cache: true

      - name: Install govulncheck
        # Pinned: an unpinned scanner is an unpinned dependency of the gate itself.
        run: go install golang.org/x/vuln/cmd/govulncheck@v1.1.4

      - name: Run govulncheck
        run: govulncheck ./...
```

### The gate is red on clean code, and that is a real finding

Requirement B.2.2 pins this job to Go 1.24, matching the rest of CI. On Go 1.24.13
`govulncheck` reports **19 reachable stdlib vulnerabilities** before any dependency is added:

```
Vulnerability #1: GO-2026-6617   Found in: net/http@go1.24.13      Fixed in: net/http@go1.26.9
Vulnerability #5: GO-2026-6608   Found in: net/textproto@go1.24.13 Fixed in: net/textproto@go1.26.9
Vulnerability #6: GO-2026-6607   Found in: crypto/tls@go1.24.13    Fixed in: crypto/tls@go1.26.9
…
Vulnerability #19: GO-2026-4601  Found in: net/url@go1.24.13       Fixed in: net/url@go1.25.8
```

These are the same CVEs Trivy reported in Task 1 — but `govulncheck` adds what Trivy cannot:
they are **reachable**, with traces such as
`main.go:37:31: quicknotes.main calls http.Server.ListenAndServe, which eventually calls url.ParseRequestURI`.

So the gate blocks every PR, which makes it a correct scanner and an unusable gate. The
resolution is the same as row 1 of the Task 1 triage: upgrade the toolchain to 1.25.11+. I did
not, because the labs pin Go 1.24, and silently bumping it would have invalidated the image
this lab is about. Documented as FIX-blocked rather than suppressed.

### Demonstrating the gate catches an added dependency

Because the baseline was already red, "red after adding a bad dep" would have proven nothing.
What *is* provable is that a new, attributable finding appears — so I tracked the finding list,
not the exit code.

**First attempt failed, instructively.** I added `github.com/dgrijalva/jwt-go v3.2.0`
(GO-2020-0017) and called `jwt.Parse`. `govulncheck` reported **19** vulnerabilities — the
stdlib ones, and nothing about jwt-go. The vulnerable symbol was never on a path from an entry
point, so reachability analysis correctly ignored it.

**Second attempt**, the canonical example: `golang.org/x/text v0.3.0` (GO-2021-0113), with
`language.Parse` called from `init()` so the call graph genuinely reaches it:

```
Vulnerability #20: GO-2021-0113
  Out-of-bounds read in golang.org/x/text/language
  Module: golang.org/x/text
    Found in: golang.org/x/text@v0.3.0
    Fixed in: golang.org/x/text@v0.3.7
    Example traces found:
      #1: vulndemo.go:12:29: quicknotes.init#1 calls language.Parse
```

19 → 20, with the added module named and traced.

| Run | State | Govulncheck | ci-ok |
|---|---|---|---|
| [38050876783](https://github.com/ovsvp/DevOps-Intro/actions/runs/38050876783) | vulnerable dep present (`x/text` v0.3.0) | **failure** (20 findings) | **failure** — PR blocked |
| [38051236565](https://github.com/ovsvp/DevOps-Intro/actions/runs/38051236565) | reverted | failure (19 stdlib findings) | failure |

In the reverted run every other job is green — `Vet (1.23)`, `Vet (1.24)`, `Test (1.23)`,
`Test (1.24)` and `Lint` all pass — so `Govulncheck` is the only thing holding the gate, which
is the behaviour the bonus asks for.

The revert commit removes `vulndemo.go` and empties `go.mod` back to no requirements;
`GO-2021-0113` disappears from the output.

### B.3 — Design questions

**h) Reachability — how does it change the triage workload?**

"This module has a CVE" is a statement about your dependency graph; "we call the affected
function" is a statement about your program. The gap between them is most of the work.

I measured the gap twice in this lab, in both directions. Trivy flagged 21 stdlib CVEs on
module presence; `govulncheck` found 19 of them reachable — so here the filter was mild,
because QuickNotes is an HTTP server and `net/http` is its core. The jwt-go attempt showed the
other extreme: a dependency with a real CVE, imported and compiled, reported by nothing,
because no call path reached the vulnerable symbol. A module-presence scanner would have paged
someone about it.

The practical effect is that reachability converts a backlog into a worklist. On a service with
a hundred dependencies, the difference is the difference between a security review that happens
and one that gets abandoned — and, just as importantly, between findings people act on and
findings people learn to close unread.

The honest caveat is that reachability is a static approximation. Reflection, `go:linkname`,
plugins and code behind build tags can all hide a real call path, so "not reachable" means "not
reachable by this analysis", not "safe". It is a prioritisation tool, not an absolution.

**i) Why pin the scanner's version?**

Because `@latest` makes the gate itself an unpinned dependency, and a gate that changes without
anyone deciding to change it fails in the worst way: silently, and in CI, where everybody is
blocked.

Three concrete consequences. The build stops being reproducible — the same commit scanned twice
a week apart can give different answers, so you can no longer tell whether a new failure is
your code or your tooling. A regression or a behaviour change in the scanner lands directly in
everyone's pipeline with no review. And it is a supply-chain hole: `go install …@latest` on
every CI run resolves and executes whatever is newest at that moment, which is exactly the
tj-actions failure mode from Lab 3, one layer down.

Pinning `@v1.1.4` means upgrades are a reviewed commit with a diff, and when the scan result
changes the cause is unambiguous.

**j) What does `govulncheck` not catch that Trivy's image scan would?**

Everything in the image that is not Go. `govulncheck` reads Go module graphs and Go call
graphs; the container is a filesystem. Specifically it would miss: OS packages from the base
layer (the `debian 13.7` target Trivy scanned separately — zero findings here only because the
base is distroless), anything vendored as a C library or non-Go binary, misconfigurations in
the `Dockerfile` or `compose.yaml` (Trivy's `config` scan found two), and secrets committed to
the filesystem (Trivy's `fs` scan found the Vagrant key).

They also disagree about *what* an artifact is. `govulncheck` analyses source and module
metadata, so it needs the code; Trivy scans the built image, so it sees what actually shipped —
including anything added by the build that is not in `go.mod`. That is why this lab runs both
rather than picking one: `govulncheck` answers "is our code affected", Trivy answers "what is
in the thing we are about to deploy".

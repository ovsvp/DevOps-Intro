# Lab 3 — CI/CD: A PR-Gated Pipeline for QuickNotes

**Path chosen: GitHub Actions.** I can sign in to github.com, so I used the default path
(`.github/workflows/ci.yml`) rather than the GitLab CI equivalent.

- PR: https://github.com/inno-devops-labs/DevOps-Intro/pull/1575 (`ovsvp:feature/lab3` → `main`)
- Workflow file: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)

---

## Task 1 — Write the PR Gate

### What the pipeline does

Three independent jobs — `vet`, `test`, `lint` — triggered on push to `main` and on every PR
targeting `main`, all running against `app/`:

- `vet` → `go vet ./...`
- `test` → `go test -race -count=1 ./...`
- `lint` → `golangci-lint run` via `golangci-lint-action`, pinned to **golangci-lint v2.5.0**

All three run on `ubuntu-24.04` (not `ubuntu-latest`). Every third-party action is pinned by
full 40-character commit SHA with the human-readable tag in a trailing comment, e.g.:

```yaml
uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0
```

`permissions: contents: read` is declared at workflow level.

### A real bug this surfaced

The action was originally pinned to `golangci-lint-action@55c2c144...` (**v6.5.2**) with
`version: v2.5.0`. The very first real run failed:

```
Error: invalid version string 'v2.5.0', golangci-lint v2 is not supported by
golangci-lint-action v6, you must update to golangci-lint-action v7.
```

Run: https://github.com/ovsvp/DevOps-Intro/actions/runs/35264247705

`golangci-lint-action` v6 only supports golangci-lint v1.x. Re-pinned to
`9fae48acfc02a90574d7c304a1758ef9895495fa` (**v7.0.1**), which supports v2.x per its own
`action.yml`. Fixed run (green): https://github.com/ovsvp/DevOps-Intro/actions/runs/35264445599

I also found and fixed a YAML indentation bug in the very first draft (the `test`/`lint` jobs
were nested one level too deep, under `vet`), which made GitHub reject the workflow outright
(0 jobs scheduled). Confirmed fixed by the same green run above.

### 1.5 — Proving the gate blocks a failing PR

Deliberately broke `TestHealth_ReportsCount` in `app/handlers_test.go`
(expected note count `1` → `2`):

- **Red run** (`Test (1.23)` and `Test (1.24)` both fail, `ci-ok` aggregation job also fails):
  https://github.com/ovsvp/DevOps-Intro/actions/runs/35265526791
  — commit [`664d68d`](https://github.com/ovsvp/DevOps-Intro/commit/664d68d)
- **Fix commit**, reverting the expected value:
  [`f31a5fd`](https://github.com/ovsvp/DevOps-Intro/commit/f31a5fd)
- **Green run again**: https://github.com/ovsvp/DevOps-Intro/actions/runs/35265660079

**Honesty note on where this was verified:** PR #1575 is opened against the upstream course
repo (`inno-devops-labs/DevOps-Intro`), and no checks ever appeared on that PR
(`gh pr checks 1575` returns "no checks reported"). I don't have admin access to that org's
Actions settings, and public template repos with hundreds of student forks commonly require a
maintainer to approve workflow runs from first-time/outside contributors before they execute —
that's the most likely explanation, but I can't confirm it without repo-admin access I don't
have. To get real, verifiable red/green evidence I could fully control, I ran the identical
workflow (same file, same commits, pushed to the same `feature/lab3` branch) directly via
`workflow_dispatch` on my own fork, and via a same-repo test PR (`ovsvp/DevOps-Intro`) — see 1.6.

### 1.6 — Branch protection

Enabled on `ovsvp/DevOps-Intro`'s `main` (via the GitHub API, since I was already scripting the
rest of this from the CLI):

- Require status checks to pass before merging: ✅
- Require branches to be up to date before merging (`strict: true`): ✅
- Required check: `ci-ok` (see note on 2.2 below for why not `vet`/`test`/`lint` directly)
- Force-pushes and branch deletion disabled

I validated this is a real, working gate — not just API output — with a same-repo PR
(`ovsvp/DevOps-Intro#1`, base `main`, head a throwaway branch off `feature/lab3`): opening it
triggered real `pull_request` runs with `mergeable: MERGEABLE` only once checks passed. Closed
and deleted after capturing the evidence (see 2.3 for why this specific PR's path-filter test
was invalid and had to be redone).

### 1.2 — Design questions

**a) Why pin the runner version (`ubuntu-24.04`) instead of `ubuntu-latest`? What breaks
otherwise?**

`ubuntu-latest` is a moving target — GitHub periodically repoints it at a new Ubuntu LTS (it
already moved from 22.04 to 24.04). Each move silently changes preinstalled package versions,
default toolchains, and OS-level behavior underneath a pipeline that made no code change at
all. A build that passed yesterday can start failing today for reasons nobody touched. Pinning
`ubuntu-24.04` makes every run reproducible against the same base image until *I* choose to
move it.

**b) Why split vet + test + lint into separate units? What would happen with one combined
job?**

Separate jobs run in parallel on separate runners (faster wall-clock) and each reports its own
named status check, so a reviewer or branch protection can see exactly *which* unit failed. A
single combined job runs its steps sequentially on one runner (slower total time), and a
failure just shows as "CI failed" with no immediate signal about whether it was a vet issue, a
test issue, or a lint issue — you have to open the log to find out.

**c) What real attack does SHA pinning prevent? Cite the date + name of the incident from
Lecture 3.**

The **tj-actions/changed-files compromise, March 2025**. Attackers compromised the action and
rewrote its published *tags* (e.g. `v35`, `v45.0.1`) to point at a different, malicious commit
that dumped CI secrets into workflow logs — affecting roughly 23,000 repositories that
referenced the action by tag. Anyone pinning `@v45` pulled the malicious code automatically on
their very next run, with zero change on their own side. A full commit SHA is immutable — the
content behind it can't be silently swapped the way a tag can — so pinning by SHA means a
compromised or malicious maintainer action can't retroactively change what your pipeline runs.

**d) What is `permissions:` and what's the principle behind it?**

`permissions:` scopes down the auto-generated `GITHUB_TOKEN` that every run gets for talking to
the GitHub API, from the (broad) repository default to only the specific scopes the job
actually needs — here, `contents: read` and nothing else. The principle is **least privilege**:
if any step, or a compromised third-party action, tries to do something the job was never
supposed to do (push code, write packages, modify PRs), a token scoped to `contents: read`
simply can't do it. It limits the blast radius of anything going wrong inside the run.

*(e is GitLab-path only — not applicable to this GitHub Actions submission.)*

---

## Task 2 — Make It Fast and Smart

### 2.1 — Caching

`actions/setup-go`'s built-in `cache: true` caches the Go module download cache and build
cache, keyed on `go.sum`.

### 2.2 — Build matrix + the required-checks trap

`vet` and `test` now run against Go `1.23` and `1.24` in parallel (`fail-fast: false`, so one
broken version doesn't cancel the other). This immediately hit the exact trap `lab3.md` warns
about: the matrix renamed the checks to `Vet (1.23)` / `Vet (1.24)` / `Test (1.23)` /
`Test (1.24)`, which no longer match the `Vet`/`Test`/`Lint` names branch protection was
originally configured to require. I used the **robust fix** the lab recommends — added a
`ci-ok` aggregation job (verbatim from the lab's own snippet) and pointed branch protection at
just that one check, so the matrix can change shape freely without ever touching branch
protection again.

### 2.3 — Path filter (and a mistake I made testing it)

`push`/`pull_request` are now scoped with `paths: ['app/**', '.github/workflows/ci.yml']`.

First attempt at demonstrating this failed in an instructive way: I opened a same-repo test PR
(`ovsvp/DevOps-Intro#1`) from a branch that only touched `README.md`, based on `feature/lab3`.
CI ran anyway. The reason: that branch's diff *against `main`* wasn't just `README.md` — `main`
doesn't have `ci.yml` yet, so the diff also included the entire new workflow file, which matches
the path filter. The path filter was working correctly; my test wasn't isolating the right
diff. I closed that PR (`gh pr close 1 --delete-branch`) rather than report a false result.

### 2.4 — Timing table

Measured via `workflow_dispatch` on my fork (`ovsvp/DevOps-Intro`), reading actual run
durations from the GitHub API (`createdAt`→`updatedAt`), not estimated:

| Scenario | Wall-clock | Run |
|---|---:|---|
| Baseline (no cache, single Go 1.24, no path filter) | **38s** | [35264445599](https://github.com/ovsvp/DevOps-Intro/actions/runs/35264445599) |
| With cache | **32s** | [35264612712](https://github.com/ovsvp/DevOps-Intro/actions/runs/35264612712) |
| With cache + matrix (1.23+1.24) | **43s** | [35265150357](https://github.com/ovsvp/DevOps-Intro/actions/runs/35265150357) |

**The cache row is boring, and that's the expected finding, not a bug.** `app/go.mod` has no
`require` block and no `go.sum` — QuickNotes has zero third-party dependencies — so there is
nothing for the module cache to store, and `cache: true` vs `false` barely moves the number
(38s → 32s is within normal run-to-run noise on a shared runner fleet, not a real effect). Per
job, the `Set up Go` step itself completes in ~1 second either way (it downloads the Go
toolchain from `go.dev`, which `setup-go`'s cache doesn't touch at all) — the actual wall-clock
is dominated by runner provisioning and checkout, not dependency resolution. On a real project
with third-party modules, the module-cache row is where you'd expect to see the saving instead.

Cache+matrix (43s) is *higher* than cache-alone (32s) because it now runs 5 jobs
(`Vet×2`, `Test×2`, `Lint`) instead of 3, plus the sequential `ci-ok` gate waiting on the
slowest of them — more parallelism, but also more runner-provisioning overhead and one extra
sequential hop at the end.

### 2.5 — Design questions

**f) Why cache `go.sum`-keyed inputs and not build outputs?**

Inputs (the modules `go.sum` pins) are deterministic — the same `go.sum` hash always resolves
to byte-identical downloaded module contents, so reusing a cached copy is always safe. Build
*outputs* depend on more than just the inputs — toolchain patch version, build flags, runner
OS/arch — so a stale or subtly mismatched cached artifact can silently produce an incorrect
result, or mask a real compile error behind a cache hit that doesn't reflect current source.
Caching only the deterministic side avoids that correctness risk while still skipping the
expensive network download.

**g) What does `fail-fast: false` change in a matrix run, and when do you actually want
`fail-fast: true`?**

The GH Actions default, `fail-fast: true`, cancels every other matrix job the instant *any one*
of them fails — so if Go 1.23 fails, the still-running Go 1.24 job gets killed before you learn
whether it would have passed. `fail-fast: false` lets every combination run to completion
independently, which is the whole point of a matrix meant to catch version-specific bugs: you
want to know *which* combination broke, not just that "the matrix failed". You'd actually want
`fail-fast: true` when the matrix is large/expensive and you only want the fastest possible
"something's broken" signal, and don't care which leg failed first — trading diagnostic detail
for saved runner-minutes.

**h) What's the risk of an attacker writing a cache from a malicious PR that protected
branches later read? What does GitHub do about it?**

If a cache written by a run on an untrusted fork PR could later be read by a run on the
protected `main` branch, an attacker could poison that cache with a tampered artifact (a
backdoored build output, a manipulated dependency) that a later, privileged run on `main` would
silently trust and reuse — a form of cache poisoning that escalates from an unprivileged PR
context into a privileged branch context. GitHub's actual mitigation is **cache scoping by
branch/ref**: a cache created on a `pull_request` run is only readable by other runs on that
same PR/branch (and its base branch during restore), not by arbitrary runs on `main` — a fork
PR's cache scope doesn't reach `main` at all. `pull_request` (as opposed to
`pull_request_target`) also runs with a read-only, secret-less `GITHUB_TOKEN`, which limits
what a malicious PR run could do even before the cache-scoping restriction applies. See GitHub's
[Caching dependencies](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows)
and [Security hardening](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions)
docs.

---

## Bonus Task — Pipeline Performance Investigation

Target: ≤ 90s. **Hit comfortably — final run is 41s.**

### B.2/B.3 — Three optimizations applied, with real before/after

All three measured the same way as Task 2: a probe commit that temporarily reverts the
optimization to get an honest "before" number, a real `workflow_dispatch` run, then a follow-up
commit restoring the optimization for the "after" number.

| Optimization applied | Before (s) | After (s) | Saving | Evidence |
|---|---:|---:|---:|---|
| 1. `GOFLAGS=-buildvcs=false` | 48 | 40 | -8 | [before](https://github.com/ovsvp/DevOps-Intro/actions/runs/35265660079) → [after](https://github.com/ovsvp/DevOps-Intro/actions/runs/35265862920) |
| 2. Keep `golangci-lint-action`'s own cache on (`skip-cache: false`, its default) | 49 | 40 | -9 | [before, `skip-cache: true` probe](https://github.com/ovsvp/DevOps-Intro/actions/runs/35266003735) → after: same run as opt 1's "after" (cache was already on by default there) |
| 3. Parallel `vet`/`test`/`lint` (no artificial `needs:`) | 138 | 41 | -97 | [before, `needs:` probe](https://github.com/ovsvp/DevOps-Intro/actions/runs/35266199136) → [after](https://github.com/ovsvp/DevOps-Intro/actions/runs/35266488816) |
| **Total wall-clock (honest net)** | **48** | **41** | **-7** | pre-bonus (Task 2 final) → all 3 applied |

**Why the "total" row isn't 8+9+97=114s of savings:** opt 1 and opt 2's "before" numbers were
measured independently against the same 48s pre-bonus baseline, so their savings overlap rather
than stack — the pipeline can only benefit from *not* re-downloading VCS info and *not*
re-downloading the linter binary at the same time, not twice over. **Opt 3's "before" (138s,
sequential) is not a real prior state of this pipeline** — `vet`/`test`/`lint` were already
running in parallel since Task 1 (no code ever added a `needs:` between them). I introduced the
`needs: [vet]` / `needs: [test]` chain purely as a temporary probe commit to get a fair,
measurable "what if this were serialized" comparison, exactly as instructed in 2.4/B.2, then
reverted it. So the 97s figure is a legitimate before/after for the *optimization itself* (a
real GitHub Actions matrix+jobs execution, not invented), but it should not be added on top of
opt 1/opt 2's savings to claim a bigger total than what the pipeline actually gained versus
where it started. The honest total is **48s → 41s**.

### B.1 / B.4 — Profiling and bottleneck analysis

Per-job breakdown (from the final all-optimizations run,
[35266488816](https://github.com/ovsvp/DevOps-Intro/actions/runs/35266488816)): each job's
"Set up job" (runner provisioning) + "Checkout" + "Set up Go" steps together take roughly
2-4 seconds; the actual work (`go vet`, `go test -race`, `golangci-lint run`) takes
15-20 seconds depending on the job; `ci-ok` runs last and adds one more sequential runner-boot
(~3s) after the slowest matrix leg finishes.

The single step that dominates the *remaining* time is runner provisioning + Go toolchain
setup, repeated once per matrix leg (5 times: Vet×2, Test×2, Lint×1) — QuickNotes itself is far
too small (a handful of files, zero dependencies) for `go vet`/`go test`/`golangci-lint` to be
the bottleneck. To meaningfully shrink this further, the change would have to be to the
*pipeline shape*, not QuickNotes' code: e.g. a single job that sets Go up once and runs vet,
test, and lint as three steps back-to-back would pay the ~2-4s setup cost once instead of five
times, at the cost of losing per-unit parallelism and per-unit status checks (see 1.2b) — a real
trade-off, not a free win. Growing QuickNotes itself (more code, more tests) wouldn't move this
number much until the actual `go test` step, not setup, becomes the dominant cost.

I'd stop optimizing at the point we're already at (~40s): for a project this size, runner
provisioning is close to the floor GitHub Actions can offer, and shaving another few seconds
off a 40s pipeline that already reports failures within a minute isn't worth trading away the
per-unit status-check granularity that makes failures easy to diagnose. It would be worth
revisiting once `go test` itself — not setup — is the largest line item, which will happen
naturally as the test suite grows.

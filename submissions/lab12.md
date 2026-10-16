# Lab 12 — WebAssembly QuickNotes Endpoint on Spin

## Toolchain

| tool | version |
|---|---|
| Spin | 3.6.3 (88d51cf 2026-04-09) |
| TinyGo | 0.41.0 darwin/arm64 (using Go 1.26.0, LLVM 20.1.1) |
| Spin Go SDK | `github.com/spinframework/spin-go-sdk/v2 v2.2.1` |
| wasmtime | 49.0.3 |
| hyperfine | 2.0.0 |

Two notes on getting there, since both cost real time:

* `spin new -t http-go` on Spin 4.2.3 scaffolds against SDK v3 and builds with
  `go tool componentize-go build`, which fails with `failed to read path for
  WIT [wit]` and does not match this lab. Spin 3.6.3 was installed alongside it
  so the scaffold uses SDK v2 and the TinyGo `-buildmode=c-shared` command the
  lab specifies.
* TinyGo 0.43 compiles the component, but the handler panics at runtime with a
  nil dereference inside `net/textproto.canonicalMIMEHeaderKey`. TinyGo 0.41
  works. 0.41 in turn refuses Go newer than 1.26, so Go 1.26.0 was installed
  via `golang.org/dl` and put ahead on `PATH`.

## Task 1 — WASM endpoint with the Spin SDK

Scaffolded with `spin new -t http-go moscow-time --accept-defaults` inside
`wasm/`.

### `wasm/moscow-time/main.go`

```go
package main

import (
	"fmt"
	"net/http"
	"time"

	spinhttp "github.com/spinframework/spin-go-sdk/v2/http"
)

// Moscow is UTC+3 year-round -- Russia abolished seasonal clock changes in
// 2011. A fixed zone is used instead of time.LoadLocation("Europe/Moscow")
// because TinyGo ships no tzdata, so the lookup would fail at runtime.
var moscow = time.FixedZone("MSK", 3*60*60)

func init() {
	spinhttp.Handle(func(w http.ResponseWriter, r *http.Request) {
		now := time.Now().In(moscow)

		w.Header().Set("Content-Type", "application/json")
		// Rendered with Sprintf rather than encoding/json: the payload is a
		// handful of fixed fields, and TinyGo's reflection support makes
		// marshalling map[string]any unreliable.
		fmt.Fprintf(w,
			`{"unix":%d,"iso":%q,"hour_minute":%q,"zone":%q,"utc_offset_hours":3}`+"\n",
			now.Unix(),
			now.Format(time.RFC3339),
			now.Format("15:04"),
			"Europe/Moscow",
		)
	})
}

// main function must be included for the compiler but is not executed.
func main() {}
```

### `wasm/moscow-time/spin.toml`

```toml
#:schema https://schemas.spinframework.dev/spin/manifest-v2/latest.json

spin_manifest_version = 2

[application]
name = "moscow-time"
version = "0.1.0"
authors = ["Valeriia Kolpakova <v.kolpakova@innopolis.university>"]
description = ""

[[trigger.http]]
route = "/time"
component = "moscow-time"

[component.moscow-time]
source = "main.wasm"
allowed_outbound_hosts = []
[component.moscow-time.build]
command = "tinygo build -target=wasip1 -buildmode=c-shared -no-debug -o main.wasm ."
watch = ["**/*.go", "go.mod"]
```

### `spin build`

```
$ spin build
Building component moscow-time with `tinygo build -target=wasip1 -buildmode=c-shared -no-debug -o main.wasm .`
Finished building all Spin components

$ ls -l main.wasm
-rw-r--r--  1 ivozhs  staff  367334 Oct 16 06:45 main.wasm
```

367 334 bytes — 359 KB.

### `spin up` and the response

```
$ spin up
Logging component stdio to ".spin/logs/"

Serving http://127.0.0.1:3000
Available Routes:
  moscow-time: http://127.0.0.1:3000/time

$ curl -s -i http://127.0.0.1:3000/time
HTTP/1.1 200 OK
content-type: application/json
content-length: 120
date: Fri, 16 Oct 2026 03:45:46 GMT

{"unix":1792122346,"iso":"2026-10-16T06:45:46+03:00","hour_minute":"06:45","zone":"Europe/Moscow","utc_offset_hours":3}
```

The host clock was `2026-10-16T03:45:46Z`, so `06:45:46+03:00` is the correct
Moscow rendering of the same instant.

### Design questions

**a) Browser WASM (`go build -target=js/wasm`) vs server WASM
(`tinygo build -target=wasip1`): what's missing in the server target, and what
do you gain?**

What is missing is the browser itself. `js/wasm` runs inside a JavaScript
engine and reaches the outside world through the `syscall/js` bridge: the DOM,
`fetch`, `localStorage`, timers, the event loop. None of that exists under
`wasip1`. There is no JS runtime to call into, no DOM, and no ambient network —
`net.Dial` is not implemented, so an ordinary Go HTTP client does not work; a
host-provided interface such as Spin's outbound HTTP is required instead. The
`js/wasm` build also carries the full upstream Go runtime, including a garbage
collector and goroutine scheduler cooperating with the JS event loop, which is
why those binaries start around several megabytes.

What is gained is a plain POSIX-flavoured interface and a much smaller, much
faster artifact. `wasip1` gives real stdin/stdout/stderr, environment
variables, command-line arguments and a capability-gated filesystem, so normal
server code shapes work unchanged. The module is 359 KB here rather than
megabytes, it instantiates in single-digit milliseconds, and it runs under any
WASI host — wasmtime, Spin, wasmCloud, a CDN edge runtime — with no browser and
no JavaScript anywhere in the picture.

**b) Why does the build need `-buildmode=c-shared`? What does the Spin host
expect the module to export? Try removing the flag and observe `spin up`.**

Spin expects the module to be a *reactor*: something the host instantiates once
and then calls into repeatedly, exporting a handler rather than a program.
Specifically it looks for `spin_http_handle_http_request` (the SDK also exports
`handle-http-request` and the canonical-ABI allocator helpers), and for
`_initialize` to run package-level initialisation — which is why the handler is
registered from `init()` and `main()` is an empty stub.

`-buildmode=c-shared` is what makes TinyGo emit that shape. The exports confirm
it; dumping the export section of both builds:

```
=== built with -buildmode=c-shared ===
  func   _initialize
  func   spin_http_handle_http_request
  func   handle-http-request
  func   canonical_abi_realloc
  ...
=== built without the flag ===
  func   _start
  func   spin_http_handle_http_request
  func   handle-http-request
  func   canonical_abi_realloc
  ...
```

With the flag the module is a reactor (`_initialize`, no `_start`). Without it
TinyGo emits a *command* module: `_start` appears, which under WASI means "run
`main()` to completion and exit".

Removing the flag and running `spin up` did **not** fail on this toolchain,
which is worth recording honestly — the request still returned HTTP 200 and
correct JSON. The reason is visible above: TinyGo keeps exporting
`spin_http_handle_http_request` either way, so Spin finds the symbol it needs
and calls it. What changed is only the entrypoint convention. That makes the
working build an accident of this version rather than something to rely on:
the module is now declaring itself a command, its `main()` is expected to run
and terminate the instance, and nothing in the contract says a host must keep
invoking exports afterwards. The flag states the intended shape rather than
leaving it to chance.

**c) Explain the capability-based security behind `allowed_outbound_hosts = []`,
and compare it to Docker's `--network none`.**

A WASM module can only do what the host hands it. There is no ambient
authority: no syscall table, no socket API, nothing reachable by default.
Network access exists for the guest only if the host imports an outbound-HTTP
function into the instance, and Spin decides that from the manifest.
`allowed_outbound_hosts = []` means the component is instantiated with no
outbound capability at all, so there is no function to call — an attempt fails
at link/instantiation time rather than being blocked somewhere downstream. The
grant is also per-component and can be narrowed to named hosts
(`["https://api.example.com"]`), which is a far finer unit than a container.

`--network none` reaches a similar end by a different route. The process keeps
the full `socket()` syscall and a complete TCP/IP stack; the kernel simply puts
it in an empty network namespace with only a loopback device, so the syscalls
succeed and the packets go nowhere. The restriction is enforced *around* a
fully capable process by the kernel, and anything that escapes the namespace —
a kernel bug, a careless `--privileged`, a mounted host socket — recovers full
network access.

The difference is deny-by-configuration versus absence-of-capability. Docker
takes something away from a process that could otherwise do it; WASM never
grants it in the first place, so the attack surface is the host's small set of
imported functions rather than the whole Linux syscall interface.

**d) Which parts of upstream Go's stdlib does TinyGo not fully support that you
hit?**

Three, all visible in the code and in the toolchain notes above:

1. **No tzdata.** `time.LoadLocation("Europe/Moscow")` cannot work: TinyGo
   ships no embedded zoneinfo and `wasip1` has no `/usr/share/zoneinfo` to read.
   Hence `time.FixedZone("MSK", 3*60*60)`, which is correct here only because
   Moscow has been a fixed UTC+3 with no DST since 2011. For a zone with
   seasonal changes this workaround would be wrong and the tzdata would have to
   be embedded explicitly.
2. **Reflection-heavy `encoding/json`.** Marshalling a `map[string]any` leans
   on reflection that TinyGo implements only partially, so the response is
   built with `fmt.Fprintf` over a literal template instead. For five fixed
   fields that is no loss, but it does not scale to a real schema.
3. **`net/textproto` in TinyGo 0.43.** The component compiled, but every
   request panicked with a nil dereference inside
   `net/textproto.canonicalMIMEHeaderKey`, reached through the SDK's header
   handling. This was not a missing feature but a miscompilation; pinning
   TinyGo 0.41 was the fix. It is the clearest illustration that TinyGo is a
   separate implementation, not a subset flag on the upstream compiler.

## Task 2 — Performance comparison vs the Lab 6 container

### Test rig

* Apple M1 Pro, 8 cores, macOS 26.5.2
* Docker Desktop, server 28.0.4 (so containers run inside a Linux VM — see the
  caveat below)
* Spin 3.6.3 serving on `127.0.0.1:3000`, container `quicknotes:lab6` on
  `127.0.0.1:8123`
* Warm latency: `hyperfine --warmup 5 --runs 50`, p50 and p95 computed from the
  exported JSON
* Cold start: 5 samples per platform, measured from process/container launch
  until the first successful HTTP response
* Both endpoints return a small JSON body and do no I/O

### Results

| metric | Lab 6 Docker | Lab 12 WASM / Spin |
|---|---|---|
| Artifact size | 13.1 MB (`quicknotes:lab6`) | 359 KB (`main.wasm`) |
| Cold start (p50) | 726 ms | 94 ms |
| Warm latency (p50) | 16.7 ms | 15.9 ms |
| Warm latency (p95) | 23.5 ms | 18.3 ms |

Cold-start samples:

```
Spin:   129, 96, 92, 94, 81 ms        -> p50 94 ms
Docker: 291, 396, 726, 1055, 969 ms   -> p50 726 ms
```

Two honest caveats about these numbers:

* **The warm figures are dominated by `curl`, not by the servers.** The
  measured command is a whole process launch, and the fastest observed run on
  *either* platform is 14.8 ms, which is the floor of spawning `curl` on this
  machine. The actual request handling is a small fraction of that, so the
  p50 gap of 0.8 ms should be read as "indistinguishable at this resolution"
  rather than as a real 5 % advantage. The p95 difference is more meaningful:
  Spin's spread is tight (14.8–19.9 ms) while Docker's tail reaches 33.8 ms,
  which is the port-forwarding proxy and the VM boundary showing up.
* **Docker cold start is inflated by Docker Desktop.** On macOS the container
  runs inside a Linux VM and `docker run` crosses that boundary, so part of the
  726 ms is virtualisation overhead that a native Linux host would not pay. The
  variance is also large (291–1055 ms) and grew across consecutive samples.
  Even allowing generously for this, the order-of-magnitude gap against Spin's
  94 ms holds — and this is the same macOS host for both.

### Design questions

**e) What dominates cold start on each platform?**

For the container: creating the sandbox, not running the program. The daemon
has to set up the writable overlay on top of the image layers, create and
configure the network namespace with a veth pair, set up the port-forwarding
proxy, apply cgroup limits, seccomp and capability sets, then `execve` the
init process — and on this macOS host every one of those steps is relayed into
the Linux VM. The Go binary itself starts in a few milliseconds; the 726 ms is
almost entirely the surrounding machinery.

For Spin: loading and instantiating the module. wasmtime reads the 359 KB
`main.wasm`, validates it, compiles it to native code with Cranelift (or loads
a cached compilation), allocates the linear memory, wires up the WASI and
`spin_http_*` imports and calls `_initialize`. There is no namespace, no
overlay filesystem, no second kernel. The remaining cost is dominated by
compilation and instantiation, which is also why Spin can keep pre-instantiated
copies around and drive the marginal cost towards microseconds.

**f) When is WASM clearly better, and when is Docker still the right choice?**

WASM wins where instances are many, short-lived and untrusted. Request-scoped
serverless and edge functions, where a 94 ms versus 726 ms cold start decides
whether scale-to-zero is usable at all; multi-tenant plugin systems, where
hundreds of customer-supplied extensions must be isolated cheaply; anywhere
density matters, since a 359 KB artifact and a few hundred KB of linear memory
beat a 13 MB image and a process tree. It is also the better fit when the same
artifact must run across operating systems and architectures unchanged.

Docker remains right for everything that looks like a normal server. Long-lived
processes where cold start is amortised to irrelevance and raw throughput
matters more. Anything needing the real POSIX surface: threads, `fork`, raw
sockets, a filesystem with real semantics, `/proc`, signals. Anything with
native dependencies or a language whose WASM story is immature — and that is
most of the ecosystem. The whole operational world is built around containers:
registries, Kubernetes, sidecars, profilers, debuggers, `docker exec` into a
running instance. QuickNotes itself is a case in point: it persists notes to a
file across requests, which fits a container and fits a request-scoped WASM
component badly.

**g) WASM's capability sandbox is stronger than Linux namespaces. Which
concrete attack does it make harder in multi-tenant settings?**

Container escape through the kernel syscall interface. A container shares one
kernel with every other tenant and keeps access to a very large attack surface
— hundreds of syscalls, plus `/proc` and `/sys`. A single memory-safety bug in
any of that is a full escape: Dirty COW (CVE-2016-5195) and Dirty Pipe
(CVE-2022-0847) both let an unprivileged process in a container write files it
should not and take the host, and the `runc` `/proc/self/exe` overwrite
(CVE-2019-5736) let a container overwrite the host runtime binary. Seccomp
filters narrow the surface but do not remove it, and tenants legitimately need
many syscalls.

A WASM guest never issues a syscall. It executes a validated instruction set
inside a linear memory it cannot address past, with no pointer to host memory
and no instruction that reaches the kernel; everything it can do arrives as
explicitly imported host functions. To escape, an attacker needs a bug in
wasmtime's own small, memory-safe-Rust-implemented set of imports, not in the
Linux kernel. The surface shrinks from a shared multi-million-line kernel to a
few dozen host functions, and the other tenants are not reachable even in
principle through a shared kernel object, because there is no shared kernel
object.

## Bonus Task — Two WASM execution models

### Build and run

Spin component (Task 1), a wasi-http reactor:

```
$ spin build
Building component moscow-time with `tinygo build -target=wasip1 -buildmode=c-shared -no-debug -o main.wasm .`
```

Standalone WASI CLI module, `wasm/wasm-cli/`:

```
$ tinygo build -o main.wasm -target=wasi -no-debug ./main.go

$ wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm
Content-Type: application/json

{"unix":1792122426,"iso":"2026-10-16T06:47:06+03:00","hour_minute":"06:47","zone":"Europe/Moscow","utc_offset_hours":3}
```

Same logic, no Spin SDK: the request arrives as CGI-style environment
variables and the response goes to stdout.

### Comparison

| | Spin component | WASI CLI module |
|---|---|---|
| Artifact | `wasm/moscow-time/main.wasm` | `wasm/wasm-cli/main.wasm` |
| Size | 367 334 B (359 KB) | 194 376 B (190 KB) |
| Entry export | `_initialize` + `spin_http_handle_http_request` | `_start` |
| Execution | instantiated once, invoked per request | fresh instance per invocation |
| Cost per request | 15.9 ms p50 end-to-end (dominated by `curl`) | 47–100 ms per `wasmtime run` |

`wasmtime run` samples: 100, 52, 50, 47, 48 ms — the first is cold, the rest
settle around 48 ms. Every one of those pays module load, validation,
compilation and instantiation again, because nothing is kept between
invocations.

The CLI module is roughly half the size because it links none of the SDK: no
`net/http` types, no router, no canonical-ABI glue — just `os.Getenv`, `time`
and `fmt`.

### Design questions

**h) Why can't the Task 1 component run under bare `wasmtime run`?**

Because it is a reactor, not a command. As the export dump under question (b)
shows, the properly built component exports `_initialize` and
`spin_http_handle_http_request` and has no `_start`. `wasmtime run` looks for
the WASI command entrypoint `_start`, so there is nothing for it to execute:

```
$ wasmtime run --env REQUEST_METHOD=GET --env PATH_INFO=/time main.wasm
$ echo $?
0
```

It produces no output and exits 0 — wasmtime instantiates the module, runs
initialisation and finds no program to run. This is the more confusing failure
mode of the two: it does not error, it silently does nothing.

Even with an entrypoint it would not work, because the component expects a
wasi-http host. Its request and response travel through the
`spin_http_handle_http_request` import/export pair with host-allocated buffers;
there is no HTTP request anywhere in a bare `wasmtime run` invocation to hand
it. That is exactly why the bonus module re-expresses the request as
environment variables and stdout — the only channels a plain WASI command has.

**i) Spin uses wasmtime internally. What does Spin add on top of it?**

wasmtime is an engine: it compiles and instantiates modules and enforces the
sandbox. It has no notion of a request. Spin supplies everything between a
socket and that engine:

* **A server and trigger model.** The HTTP listener, the accept loop, and the
  mapping from a request to a component invocation — including non-HTTP
  triggers such as Redis.
* **The manifest and routing.** `spin.toml` declares routes (`/time`),
  components and their sources, so the mapping from URL to module is
  configuration rather than code.
* **The wasi-http host implementation.** The `spin_http_*` imports and the
  marshalling of a real `http::Request` into guest memory and back.
* **Instance pooling and pre-instantiation.** Modules are compiled once at
  startup, and instances are created from a template per request, which is why
  warm invocations cost microseconds of engine time rather than the ~48 ms a
  fresh `wasmtime run` pays.
* **Capability policy.** `allowed_outbound_hosts` is a Spin concept; Spin
  decides which host functions to import into each component, and enforces the
  allow-list on outbound requests.
* **Operational plumbing.** Build orchestration (`spin build` runs the per
  component command), per-component stdio logging to `.spin/logs/`, key-value
  and SQLite host services, deployment.

**j) Name one workload that suits per-invocation `wasmtime run` and one that
suits Spin's persistent server.**

Per-invocation `wasmtime run` suits a batch or CI step: running untrusted
user-submitted code in an autograder, or a scheduled data transform that
executes once an hour. The job is already seconds or minutes long, so ~48 ms of
startup is noise, there is no socket to keep open, and a fresh instance per run
gives the strongest possible isolation with the simplest possible operational
story — no daemon.

Spin's persistent server suits exactly this lab's endpoint: a public HTTP API
answering many small requests. Paying module load and compilation once at
startup instead of 48 ms on every request is the entire difference between a
usable API and an unusable one, and routing, logging and the outbound policy
come with it.

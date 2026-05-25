# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project shape

Carbonyl is a Chromium-based terminal browser. It is built from two pieces that get linked together:

- **Core** (`src/`) — Rust `cdylib` named `libcarbonyl`. Owns terminal I/O (input parsing, painting, quadrant/bitmap rendering, navigation UI). Builds in seconds.
- **Runtime** — a patched Chromium `headless_shell` that dynamically loads `libcarbonyl` and calls into it through a C FFI. Lives in `chromium/src/` after a `gclient sync`. Builds in ~1 hour and requires ~100 GB.

The runtime is *not* in this repo as source; it is a fork-by-patches of upstream Chromium/Skia/WebRTC at pinned SHAs. The patches live in `chromium/patches/{chromium,skia,webrtc}/` and are applied via `git am` on top of those SHAs in the checked-out Chromium tree. The SHAs are hard-coded in `scripts/patches.sh` — if you bump them, you have to bump them there.

Practically: if you're only changing Rust code you do **not** need to build Chromium. Build `libcarbonyl` and drop the shared library into a pre-built Carbonyl release.

## Build & run

Cargo target dir is overridden to `build/` (see `.cargo/config.toml`), not the default `target/`.

```bash
# Rust core only — fast
cargo build                                    # debug
cargo build --release                          # release; output: build/release/libcarbonyl.{so,dylib}

# First-time Chromium setup (slow, ~100 GB)
./scripts/gclient.sh sync                      # fetch Chromium source into chromium/src/
./scripts/patches.sh apply                     # apply chromium/skia/webrtc patches at pinned SHAs
./scripts/gn.sh args out/Default               # configure; paste contents of src/browser/args.gn when prompted

# Build the runtime (builds cargo first, copies libcarbonyl into out/<target>, then runs ninja)
./scripts/build.sh Default
# Skip the cargo step: CARBONYL_SKIP_CARGO_BUILD=1 ./scripts/build.sh Default

# Run it
./scripts/run.sh Default https://wikipedia.org

# Docker image (uses pre-built binaries from build/pre-built/<triple>/)
./scripts/docker-build.sh Default amd64
```

Other scripts: `patches.sh save` regenerates the patch files from the current state of `chromium/src/`; `npm-package.sh` produces the npm tarball; `release.sh`, `docker-push.sh`, `runtime-{push,pull}.sh` are CI-side.

There is no Rust test suite, lint config, or CI test job — `cargo build` (and `cargo clippy` if you want) is the loop.

## The Rust↔C++ bridge

`src/browser/bridge.rs` is the single FFI surface between the Rust core and the C++ runtime. Every cross-language call goes through `#[no_mangle] extern "C" fn carbonyl_*` functions here:

- C++ owns the process and the Chromium event loops. It creates a `RendererBridge` (an opaque `*const Mutex<RendererBridge>`) via `carbonyl_renderer_create`, then feeds it text/bitmap draw calls (`carbonyl_renderer_draw_text`, `carbonyl_renderer_draw_bitmap`), navigation state (`carbonyl_renderer_push_nav`), resizes, etc.
- Rust calls back into C++ via a `BrowserDelegate` vtable (struct of `extern "C" fn` pointers) passed to `carbonyl_renderer_listen`. The bridge dispatches keyboard/mouse/scroll events from `input::listen()` and posts them onto the browser thread using the delegate's `post_task` trampoline.
- The C-side declarations live in `src/browser/bridge.{h,cc}` plus `render_service_impl.{h,cc}` and `renderer.{h,cc}`, all compiled into the Chromium tree via `src/browser/BUILD.gn` (which expects `libcarbonyl` at `//carbonyl/build/<triple>/release/`).
- A Mojo interface `CarbonylRenderService` (`src/browser/carbonyl.mojom`) carries text draw calls from the renderer process to the browser process before they reach Rust.

When adding a new cross-language call: declare it as a `#[no_mangle] extern "C"` in `bridge.rs`, mirror the prototype in `bridge.h`, and add it to the appropriate `BUILD.gn` target. Keep types `#[repr(C)]` — see `CSize`/`CPoint`/`CRect`/`CColor`/`CText`.

## Process model & the shell-mode re-exec

The `carbonyl` binary execs itself. On first invocation, `bridge.rs::main` sets up the terminal, then spawns `env::current_exe()` again with the env var `CARBONYL_ENV_SHELL_MODE=1` and Chromium's own argv. The child re-enters `main`, sees `shell_mode`, and falls through to Chromium's normal startup. The parent waits for the child, restores the terminal, and prints stderr (only on non-zero exit or with `--debug`). Without bitmap mode the parent also injects `--disable-threaded-scrolling --disable-threaded-animation` into the child's argv.

This matters: there is no separate "launcher" binary, and you cannot reason about the lifecycle by looking only at the Rust entrypoint without knowing about the re-exec.

CLI parsing (`src/cli/cli.rs`) recognizes `-f/--fps`, `-z/--zoom`, `-b/--bitmap`, `-d/--debug`, `-h/--help`, `-v/--version`; everything else is forwarded to Chromium. Flags also propagate through env vars (`CARBONYL_ENV_*`) so the child process sees them.

## Source layout (Rust)

- `src/browser/` — the FFI bridge (Rust + C++ files compiled into Chromium).
- `src/cli/` — argv parsing and the `--help`/`--version` short-circuit programs.
- `src/input/` — stdin parser for ANSI/DCS sequences → `Event`s (keyboard, mouse, scroll, terminal capability probes). `listen.rs` is the blocking read loop.
- `src/output/` — terminal painter. `quad.rs`/`quantizer.rs`/`kd_tree.rs` implement quadrant-character rendering (sub-cell pixel approximation using Unicode quadrant glyphs); `render_thread.rs` owns a dedicated thread that the bridge posts closures to.
- `src/ui/navigation.rs` — the address-bar/back/forward chrome drawn in the top row.
- `src/gfx/` — `Point`/`Size`/`Rect`/`Color`/`Vector` with a `Cast` trait for numeric conversions.
- `src/utils/` — logging macro (gated on `--debug`) and small helpers.

## Patching Chromium

Workflow when modifying Chromium itself:

1. `./scripts/patches.sh apply` once — leaves `chromium/src/` checked out at the pinned SHA + patches applied as real commits.
2. Edit, commit your changes in `chromium/src/` (and/or `third_party/skia`, `third_party/webrtc`) on top.
3. `./scripts/patches.sh save` regenerates `chromium/patches/**/*.patch` from those commits via `git format-patch`.

The pinned upstream SHAs are at the top of `scripts/patches.sh`. The Chromium build args Carbonyl needs live in `src/browser/args.gn` and are imported by the user's `out/<target>/args.gn` via `import("//carbonyl/src/browser/args.gn")`. That import path implies `src/` is exposed inside the Chromium tree as `//carbonyl/src/` (the repo root is symlinked/checked out as `chromium/src/carbonyl/`).

#!/usr/bin/env bash

export CARBONYL_ROOT=$(cd $(dirname -- "$0") && dirname -- "$(pwd)")
export INSTALL_DEPOT_TOOLS="true"

cd "$CARBONYL_ROOT"
source scripts/env.sh

target="$1"
cpu="$2"

if [ ! -z "$target" ]; then
    shift
fi
if [ ! -z "$cpu" ]; then
    shift
fi

triple=$(scripts/platform-triple.sh "$cpu")

if [ -z "$CARBONYL_SKIP_CARGO_BUILD" ]; then
    if [ -z "$MACOSX_DEPLOYMENT_TARGET" ]; then
        export MACOSX_DEPLOYMENT_TARGET=10.13
    fi

    cargo build --target "$triple" --release
fi

if [ -f "build/$triple/release/libcarbonyl.dylib" ]; then
    cp "build/$triple/release/libcarbonyl.dylib" "$CHROMIUM_SRC/out/$target"
    install_name_tool \
        -id @executable_path/libcarbonyl.dylib \
        "build/$triple/release/libcarbonyl.dylib"
else
    # M148+ ld.lld rejects libcarbonyl.so's symbol-version metadata when
    # linking it into libcarbonyl_renderer.so ("version definition index N
    # out of bounds"). Clear the per-symbol GLIBC/GCC version tags via
    # patchelf so the imported symbols become unversioned defaults; this
    # leaves a coherent .gnu.version section (still referenced by the
    # dynamic table) so the runtime loader is also happy.
    sofile="build/$triple/release/libcarbonyl.so"
    readelf -W --dyn-syms "$sofile" \
        | awk '/@@?GLIBC|@@?GCC/ { for (i=1;i<=NF;i++) if ($i ~ /@/) { sub(/@.*/, "", $i); print $i; break } }' \
        | sort -u \
        | while read -r sym; do
            patchelf --clear-symbol-version "$sym" "$sofile"
          done
    cp "$sofile" "$CHROMIUM_SRC/out/$target"
fi

cd "$CHROMIUM_SRC/out/$target"

ninja headless:headless_shell "$@"

#!/bin/bash -e
set -o pipefail

deps="ninja patchelf unzip curl pip flex bison zip git perl python3 ccache"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r28"

check_deps(){
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Missing: $dep"
            exit 1
        fi
    done

    pip install meson mako --break-system-packages >/dev/null 2>&1 || true
}

prepare_ndk(){
    mkdir -p "$workdir"
    cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" \
            --output "${ndkver}-linux.zip"
        unzip -q "${ndkver}-linux.zip"
    fi

    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

compile_mesa(){
    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="mesa-26.3.1"
    local build_name="Turnip-26.3.1-PocoF1-Android10"
    local output_tag="V26.3.1-Android10"

    echo "Cloning Mesa $branch..."

    cd "$workdir"
    rm -rf mesa

    git clone --depth 1 -b "$branch" "$repo_url" mesa
    cd mesa

    local build_dir="$workdir/mesa/build"
    rm -rf "$build_dir"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local cver="34"

    cat <<EOF > android-cross.txt
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang++', '--sysroot=$ndk_sys']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF

    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    meson setup "$build_dir" --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=29 \
        -Dandroid-stub=true \
        -Dandroid-libbacktrace=disabled \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Db_lto=false \
        -Dwerror=false

    ninja -C "$build_dir"

    local lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"

    if [ ! -f "$lib" ]; then
        echo "Build failed: $lib not found"
        exit 1
    fi

    local pkg_dir="$workdir/pkg_$output_tag"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"

    cp "$lib" "$pkg_dir/vulkan.ad07XX.so"
    cd "$pkg_dir"

    # JANGAN strip file .so.
    # Section header ELF harus tetap ada supaya loader Android 10 bisa memuatnya.

    patchelf --remove-rpath vulkan.ad07XX.so
    patchelf --set-soname "vulkan.ad07XX.so" vulkan.ad07XX.so

    local readelf="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

    echo "=== Versioned libc symbols ==="
    "$readelf" --dyn-syms --wide vulkan.ad07XX.so | \
        grep -E 'LIBC_[A-Z0-9]+' || true

    echo "=== Android 10 compatibility symbols ==="
    for sym in call_once mtx_init mtx_lock mtx_unlock \
               cnd_init cnd_signal cnd_wait thrd_create thrd_join \
               qsort_r pthread_getaffinity_np pthread_setaffinity_np; do
        if "$readelf" --dyn-syms --wide vulkan.ad07XX.so | grep -qw "$sym"; then
            echo "FOUND: $sym"
        fi
    done

    cat <<EOF > meta.json
{
  "schemaVersion": 1,
  "name": "$build_name",
  "description": "Mesa Turnip 26.3.1 for Adreno 6xx / Poco F1 (Android 10)",
  "author": "StevenMX",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$output_tag",
  "minApi": 29,
  "libraryName": "vulkan.ad07XX.so"
}
EOF

    zip -9 "$workdir/Turnip-${output_tag}.zip" vulkan.ad07XX.so meta.json
    echo "Done: Turnip-${output_tag}.zip"
}

check_deps
prepare_ndk
compile_mesa

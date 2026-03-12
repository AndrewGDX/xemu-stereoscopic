#!/usr/bin/env bash

set -euo pipefail
set -o physical

shopt -s nullglob

project_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
configure_script="${project_source_dir}/configure"
default_job_count='12'
default_build_dir='build'

append_flag() {
    local var_name="${1}"
    local addition="${2}"
    local current="${!var_name:-}"

    if [[ -z "${addition}" ]]; then
        return
    fi

    if [[ -n "${current}" ]]; then
        printf -v "${var_name}" '%s %s' "${current}" "${addition}"
    else
        printf -v "${var_name}" '%s' "${addition}"
    fi
}

show_help() {
    cat <<EOF
Usage: ./build.sh [options] [configure options]

Options:
  -jN, -j N           Set parallel job count
  --debug             Enable debug build options
  -p PLATFORM         Override platform (Linux, Darwin, win64-cross, ...)
  -a ARCH             Override target architecture for platform packaging
  --build-dir DIR     Reuse a specific build directory (default: ${default_build_dir})
  --reconfigure       Force a configure pass before building
  -h, --help          Show this help text

This script keeps the build directory intact and only re-runs configure when
the requested build configuration changes.
EOF
}

package_windows() {
    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"
    cp "${build_output}" "${dist_dir}/xemu.exe"
    python3 "${project_source_dir}/get_deps.py" "${dist_dir}/xemu.exe" "${dist_dir}"
}

package_wincross() {
    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"
    cp "${build_output}" "${dist_dir}/xemu.exe"
    python3 "${project_source_dir}/scripts/gen-license.py" --platform windows > "${dist_dir}/LICENSE.txt"
}

package_macos() {
    local exe_path="${dist_dir}/xemu.app/Contents/MacOS/xemu"
    local bundle_lib_dir="${dist_dir}/xemu.app/Contents/Libraries/${target_arch}"
    local bundle_lib_rpath="../Libraries/${target_arch}"
    local icon_dir="${build_dir}/xemu.iconset"
    local moltenvk_src="${project_source_dir}/macos-libs/${target_arch}/opt/local/lib/libMoltenVK.dylib"
    local xemu_version
    local dep
    local dep_basename
    local new_path
    local lib_file

    rm -rf "${dist_dir}"

    mkdir -p "${dist_dir}/xemu.app/Contents/MacOS"
    cp "${build_output}" "${exe_path}"

    mkdir -p "${bundle_lib_dir}"
    if [[ -e "${moltenvk_src}" ]]; then
        cp "${moltenvk_src}" "${bundle_lib_dir}/"
    fi

    dylibbundler -cd -of -b -x "${exe_path}" \
        -d "${bundle_lib_dir}/" \
        -p "@executable_path/${bundle_lib_rpath}/" \
        -s "${project_source_dir}/macos-libs/${target_arch}/opt/local/lib/"

    while IFS= read -r dep; do
        dep_basename="$(basename "${dep}")"
        new_path="@executable_path/${bundle_lib_rpath}/${dep_basename}"
        echo "Fixing ${exe_path} dependency ${dep_basename} -> ${new_path}"
        install_name_tool -change "${dep}" "${new_path}" "${exe_path}"
    done < <(otool -L "${exe_path}" | awk '/\/opt\/local\// {print $1}')

    for lib_file in "${bundle_lib_dir}"/*.dylib; do
        while IFS= read -r dep; do
            dep_basename="$(basename "${dep}")"
            new_path="@rpath/${dep_basename}"
            echo "Fixing ${lib_file} dependency ${dep_basename} -> ${new_path}"
            install_name_tool -change "${dep}" "${new_path}" "${lib_file}"
            codesign -s - -f "${lib_file}"
        done < <(otool -L "${lib_file}" | awk '/\/opt\/local\// {print $1}')
    done

    mkdir -p "${dist_dir}/xemu.app/Contents/Resources"
    rm -rf "${icon_dir}"
    mkdir -p "${icon_dir}"
    for r in 16 32 128 256 512; do
        cp "${project_source_dir}/ui/icons/xemu_${r}x${r}.png" \
            "${icon_dir}/icon_${r}x${r}.png"
    done
    iconutil --convert icns --output "${dist_dir}/xemu.app/Contents/Resources/xemu.icns" "${icon_dir}"

    cp "${project_source_dir}/Info.plist" "${dist_dir}/xemu.app/Contents/"

    if [[ -e "${project_source_dir}/XEMU_VERSION" ]]; then
        xemu_version="$(cut -f1 -d- < "${project_source_dir}/XEMU_VERSION")"
    else
        xemu_version="0.0.0"
    fi

    plutil -replace CFBundleShortVersionString -string "${xemu_version}" \
        "${dist_dir}/xemu.app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "${xemu_version}" \
        "${dist_dir}/xemu.app/Contents/Info.plist"

    codesign --force --deep --preserve-metadata=entitlements,requirements,flags,runtime \
        --sign - "${exe_path}"
    python3 "${project_source_dir}/scripts/gen-license.py" \
        --version-file="${project_source_dir}/macos-libs/${target_arch}/INSTALLED" \
        > "${dist_dir}/LICENSE.txt"
}

package_linux() {
    rm -rf "${dist_dir}"
    mkdir -p "${dist_dir}"
    cp "${build_output}" "${dist_dir}/xemu"
    if [[ -e "${project_source_dir}/XEMU_LICENSE" ]]; then
        cp "${project_source_dir}/XEMU_LICENSE" "${dist_dir}/LICENSE.txt"
    else
        python3 "${project_source_dir}/scripts/gen-license.py" > "${dist_dir}/LICENSE.txt"
    fi
}

get_job_count() {
    if command -v nproc >/dev/null; then
        nproc
    else
        case "$(uname -s)" in
            Linux)
                egrep '^processor' /proc/cpuinfo | wc -l
                ;;
            FreeBSD)
                sysctl -n hw.ncpu
                ;;
            Darwin)
                sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu
                ;;
            MSYS_NT-*|CYGWIN_NT-*|MINGW*_NT-*)
                if command -v wmic >/dev/null; then
                    wmic cpu get NumberOfLogicalProcessors/Format:List | grep -m1 '=' | cut -f2 -d'='
                else
                    echo "${NUMBER_OF_PROCESSORS:-${default_job_count}}"
                fi
                ;;
            *)
                echo "${default_job_count}"
                ;;
        esac
    fi
}

most_recent_macosx_sdk_ver() {
    local min_ver="${1}"
    local macos_sdk_base='/Library/Developer/CommandLineTools/SDKs'
    local sdks=("${macos_sdk_base}"/MacOSX[0-9]*.[0-9]*.sdk)
    local i
    local newest_sdk_ver
    local sdk_path

    if ((${#sdks[@]})); then
        for i in "${!sdks[@]}"; do
            local newval="${sdks[i]##${macos_sdk_base}/MacOSX}"
            sdks[i]="${newval%%.sdk}"
        done
    fi

    IFS=$'\n' sdks=($(sort -nr <<<"${sdks[*]:-}"))
    unset IFS

    newest_sdk_ver="${sdks[0]:-}"
    sdk_path="${macos_sdk_base}/MacOSX${newest_sdk_ver}.sdk"

    if [[ -z "${newest_sdk_ver}" ]] || [[ ! -d "${sdk_path}" ]]; then
        echo ''
        return
    fi

    if ! LC_ALL=C awk 'BEGIN {exit ('"${newest_sdk_ver}"' < '"${min_ver}"')}' >/dev/null; then
        echo ''
        return
    fi

    echo "${sdk_path}"
}

any_newer_than() {
    local target_file="${1}"
    shift
    local candidate

    if [[ ! -e "${target_file}" ]]; then
        return 0
    fi

    for candidate in "$@"; do
        if [[ -e "${candidate}" && "${candidate}" -nt "${target_file}" ]]; then
            return 0
        fi
    done

    return 1
}

package_needed_linux() {
    if [[ ! -e "${dist_dir}/xemu" ]] || [[ ! -e "${dist_dir}/LICENSE.txt" ]]; then
        return 0
    fi

    if any_newer_than "${dist_dir}/xemu" "${build_output}"; then
        return 0
    fi

    if [[ -e "${project_source_dir}/XEMU_LICENSE" ]]; then
        any_newer_than "${dist_dir}/LICENSE.txt" "${project_source_dir}/XEMU_LICENSE"
        return
    fi

    any_newer_than "${dist_dir}/LICENSE.txt" \
        "${project_source_dir}/scripts/gen-license.py"
}

package_needed_windows() {
    if [[ ! -e "${dist_dir}/xemu.exe" ]]; then
        return 0
    fi

    any_newer_than "${dist_dir}/xemu.exe" "${build_output}"
}

package_needed_wincross() {
    if [[ ! -e "${dist_dir}/xemu.exe" ]] || [[ ! -e "${dist_dir}/LICENSE.txt" ]]; then
        return 0
    fi

    if any_newer_than "${dist_dir}/xemu.exe" "${build_output}"; then
        return 0
    fi

    any_newer_than "${dist_dir}/LICENSE.txt" \
        "${project_source_dir}/scripts/gen-license.py"
}

package_needed_macos() {
    local app_exe="${dist_dir}/xemu.app/Contents/MacOS/xemu"
    local app_info="${dist_dir}/xemu.app/Contents/Info.plist"
    local app_icon="${dist_dir}/xemu.app/Contents/Resources/xemu.icns"
    local source_file

    if [[ ! -e "${app_exe}" ]] || [[ ! -e "${app_info}" ]] || [[ ! -e "${app_icon}" ]] \
        || [[ ! -e "${dist_dir}/LICENSE.txt" ]]; then
        return 0
    fi

    if any_newer_than "${app_exe}" "${build_output}"; then
        return 0
    fi

    if any_newer_than "${app_info}" \
        "${project_source_dir}/Info.plist" \
        "${project_source_dir}/XEMU_VERSION"; then
        return 0
    fi

    for source_file in "${project_source_dir}"/ui/icons/xemu_*.png; do
        if [[ "${source_file}" -nt "${app_icon}" ]]; then
            return 0
        fi
    done

    if any_newer_than "${dist_dir}/LICENSE.txt" \
        "${project_source_dir}/scripts/gen-license.py" \
        "${project_source_dir}/macos-libs/${target_arch}/INSTALLED"; then
        return 0
    fi

    return 1
}

maybe_package() {
    local package_needed='false'

    case "${postbuild}" in
        package_linux)
            package_needed_linux && package_needed='true'
            ;;
        package_macos)
            package_needed_macos && package_needed='true'
            ;;
        package_windows)
            package_needed_windows && package_needed='true'
            ;;
        package_wincross)
            package_needed_wincross && package_needed='true'
            ;;
        *)
            package_needed='false'
            ;;
    esac

    if [[ "${package_needed}" == 'true' ]]; then
        "${postbuild}"
    else
        echo "Package is up to date; skipping dist refresh."
    fi
}

write_config_signature() {
    local output_path="${1}"
    local arg

    {
        printf 'platform=%q\n' "${platform}"
        printf 'target_arch=%q\n' "${target_arch}"
        printf 'debug=%q\n' "${debug}"
        printf 'target=%q\n' "${target}"
        printf 'postbuild=%q\n' "${postbuild}"
        printf 'extra_cflags=%q\n' "${extra_cflags}"
        printf 'extra_ldflags=%q\n' "${sys_ldflags}"
        printf 'env_cflags=%q\n' "${configure_env_cflags}"
        printf 'env_ldflags=%q\n' "${configure_env_ldflags}"
        printf 'env_pkg_config_libdir=%q\n' "${configure_env_pkg_config_libdir}"
        printf 'env_ar=%q\n' "${configure_env_ar}"
        printf 'build_dir=%q\n' "${build_dir}"
        if ((${#configure_opts[@]})); then
            for arg in "${configure_opts[@]}"; do
                printf 'configure_opt=%q\n' "${arg}"
            done
        fi
        if ((${#forwarded_args[@]})); then
            for arg in "${forwarded_args[@]}"; do
                printf 'forwarded_arg=%q\n' "${arg}"
            done
        fi
    } > "${output_path}"
}

needs_configure() {
    local temp_signature

    if [[ "${force_reconfigure}" == 'y' ]]; then
        return 0
    fi

    if [[ ! -f "${build_dir}/config.status" ]] || [[ ! -f "${build_dir}/config-host.mak" ]] \
        || [[ ! -f "${build_dir}/build.ninja" ]]; then
        return 0
    fi

    if any_newer_than "${build_dir}/config-host.mak" \
        "${project_source_dir}/configure" \
        "${project_source_dir}/scripts/meson-buildoptions.sh" \
        "${project_source_dir}/pythondeps.toml" \
        "${project_source_dir}/QEMU_VERSION"; then
        return 0
    fi

    temp_signature="$(mktemp "${TMPDIR:-/tmp}/build-config.XXXXXX")"
    write_config_signature "${temp_signature}"

    if [[ ! -f "${config_signature_file}" ]] || ! cmp -s "${temp_signature}" "${config_signature_file}"; then
        rm -f "${temp_signature}"
        return 0
    fi

    rm -f "${temp_signature}"
    return 1
}

run_configure() {
    local -a cmd

    mkdir -p "${build_dir}"

    case "${platform}" in
        Darwin)
            python3 "${project_source_dir}/scripts/download-macos-libs.py" "${target_arch}"
            ;;
    esac

    cmd=(
        "${configure_script}"
        "--extra-cflags=${extra_cflags}"
        "--extra-ldflags=${sys_ldflags}"
        '--target-list=i386-softmmu'
    )

    if ((${#configure_opts[@]})); then
        cmd+=("${configure_opts[@]}")
    fi
    if ((${#forwarded_args[@]})); then
        cmd+=("${forwarded_args[@]}")
    fi

    echo "Configuring ${build_dir}..."
    (
        cd "${build_dir}"
        export CFLAGS="${configure_env_cflags}"
        export LDFLAGS="${configure_env_ldflags}"
        if [[ -n "${configure_env_pkg_config_libdir}" ]]; then
            export PKG_CONFIG_LIBDIR="${configure_env_pkg_config_libdir}"
        else
            unset PKG_CONFIG_LIBDIR 2>/dev/null || true
        fi
        if [[ -n "${configure_env_ar}" ]]; then
            export AR="${configure_env_ar}"
        fi
        "${cmd[@]}"
    )

    write_config_signature "${config_signature_file}"
}

run_build() {
    local -a cmd

    if command -v ninja >/dev/null && [[ -f "${build_dir}/build.ninja" ]]; then
        cmd=(ninja -C "${build_dir}" -j "${job_count}" "${target}")
    else
        cmd=(make -C "${build_dir}" -j"${job_count}" "${target}")
    fi

    echo "Building ${target} in ${build_dir}..."
    time "${cmd[@]}" 2>&1 | tee "${build_log}"
}

job_count="$(get_job_count)" 2>/dev/null || job_count="${default_job_count}"
job_count="${job_count:-${default_job_count}}"
build_dir="${BUILD_DIR:-${default_build_dir}}"
target_arch="$(uname -m)"
platform="$(uname -s)"
debug=''
force_reconfigure=''
target='qemu-system-i386'
postbuild=''
build_output=''
sys_cflags=''
sys_ldflags=''
build_cflags=''
extra_cflags='-DXBOX=1'
configure_env_cflags="${CFLAGS:-}"
configure_env_ldflags="${LDFLAGS:-}"
configure_env_pkg_config_libdir="${PKG_CONFIG_LIBDIR:-}"
configure_env_ar="${AR:-}"
dist_dir="${project_source_dir}/dist"

declare -a configure_opts=()
declare -a forwarded_args=()

while [[ $# -gt 0 ]]; do
    case "${1}" in
        -j)
            job_count="${2}"
            shift 2
            ;;
        -j*)
            job_count="${1#-j}"
            shift
            ;;
        --debug)
            debug='y'
            shift
            ;;
        -p)
            platform="${2}"
            shift 2
            ;;
        -a)
            target_arch="${2}"
            shift 2
            ;;
        --build-dir)
            build_dir="${2}"
            shift 2
            ;;
        --reconfigure)
            force_reconfigure='y'
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            forwarded_args=("$@")
            break
            ;;
    esac
done

case "${build_dir}" in
    /*) ;;
    *)
        build_dir="${project_source_dir}/${build_dir}"
        ;;
esac

build_log="${build_dir}/build.log"
config_signature_file="${build_dir}/.build-config"

if [[ -n "${debug}" ]]; then
    build_cflags='-DXEMU_DEBUG_BUILD=1'
    configure_opts+=(--enable-debug --enable-trace-backends=log)
fi

case "${platform}" in
    Linux)
        echo 'Compiling for Linux...'
        sys_cflags='-Wno-error=redundant-decls'
        configure_opts+=(--disable-werror)
        postbuild='package_linux'
        build_output="${build_dir}/qemu-system-i386"
        ;;
    Darwin)
        echo "Compiling for MacOS for ${target_arch}..."
        if [[ "${target_arch}" == 'arm64' ]]; then
            macos_min_ver='13.7.4'
        elif [[ "${target_arch}" == 'x86_64' ]]; then
            macos_min_ver='12.7.5'
        else
            echo "Unsupported arch ${target_arch}" >&2
            exit 1
        fi

        sdk="$(most_recent_macosx_sdk_ver "${macos_min_ver}")"
        if [[ -z "${sdk}" ]]; then
            echo "SDK >= ${macos_min_ver} not found. Install Xcode Command Line Tools" >&2
            exit 1
        fi

        lib_prefix="${project_source_dir}/macos-libs/${target_arch}/opt/local"
        append_flag configure_env_cflags "-arch ${target_arch}"
        append_flag configure_env_cflags "-target ${target_arch}-apple-macos${macos_min_ver}"
        append_flag configure_env_cflags "-isysroot ${sdk}"
        append_flag configure_env_cflags "-I${lib_prefix}/include"
        append_flag configure_env_cflags "-mmacosx-version-min=${macos_min_ver}"
        append_flag configure_env_ldflags "-arch ${target_arch}"
        append_flag configure_env_ldflags "-isysroot ${sdk}"
        if [[ "${target_arch}" == 'x86_64' ]]; then
            sys_cflags='-march=ivybridge'
        fi
        sys_ldflags='-headerpad_max_install_names'
        configure_env_pkg_config_libdir="${lib_prefix}/lib/pkgconfig"
        configure_opts+=(--disable-cocoa --cross-prefix=)
        postbuild='package_macos'
        build_output="${build_dir}/qemu-system-i386"
        ;;
    CYGWIN*|MINGW*|MSYS*)
        echo 'Compiling for Windows...'
        sys_cflags='-Wno-error'
        append_flag configure_env_cflags '-lIphlpapi -lCrypt32'
        postbuild='package_windows'
        target='qemu-system-i386w.exe'
        build_output="${build_dir}/qemu-system-i386w.exe"
        ;;
    win64-cross)
        echo 'Cross-compiling for Windows...'
        if [[ -z "${configure_env_ar}" && -n "${CROSSAR:-}" ]]; then
            configure_env_ar="${CROSSAR}"
        fi
        sys_cflags='-Wno-error'
        configure_opts+=("--cross-prefix=${CROSSPREFIX:-}" --static)
        postbuild='package_wincross'
        target='qemu-system-i386w.exe'
        build_output="${build_dir}/qemu-system-i386w.exe"
        ;;
    *)
        echo "Unsupported platform ${platform}, aborting" >&2
        exit 1
        ;;
esac

append_flag extra_cflags "${build_cflags}"
append_flag extra_cflags "${sys_cflags}"
append_flag extra_cflags "${configure_env_cflags}"

if needs_configure; then
    run_configure
else
    echo "Configuration is unchanged; skipping configure."
fi

run_build
maybe_package

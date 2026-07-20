#!/usr/bin/env bash
set -euo pipefail
export LANG=en_US.UTF-8

# =========================
# VLESS TCP REALITY Vision 自动化脚本
# 增强版：XHTTP支持 + 双栈链接 + WARP分流 + 系统优化工具
# =========================

# Bash 版本检查 (需要 4.3+ 支持 nameref 和 wait -n)
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    echo "Error: This script requires bash 4.3 or newer (current: ${BASH_VERSION})"
    echo "Please upgrade bash or use a newer system"
    exit 1
fi

# This file is the stable launcher. The maintained implementation lives in lib/;
# remote process-substitution downloads the generated, self-contained bundle.

__phb_modules=(
    00_security_state.sh
    10_runtime_platform_ui.sh
    15_xray_release.sh
    20_installers_restart.sh
    30_provision_network.sh
    40_config_share.sh
    50_node_commands.sh
    60_system_tools.sh
    70_ports_logs.sh
    80_timesync.sh
    90_main.sh
)
__phb_tmp_root=""
__phb_tmp_root_id=""
__phb_tmp_signal_pending=""
__phb_tmp_parent="${TMPDIR:-/tmp}"
__phb_runtime_file=""
__phb_expected_runtime_bytes=""
__phb_expected_runtime_sha=""
__phb_entry_file=""
__phb_local_root=""
__phb_expected_header_bytes=536
__phb_expected_header_sha="3df1cad78a529b3a24d9a027c1dd8ca2941af51a0933a381cc6cefb6b0453533"

__phb_error() {
    printf 'proxy-hub: %s\n' "$*" >&2
}

__phb_hash_file() {
    local file="$1" output
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        output=$(openssl dgst -sha256 "$file") || return 1
        printf '%s\n' "${output##*= }"
    else
        __phb_error "sha256sum, shasum, or openssl is required"
        return 1
    fi
}

__phb_hash_module_stream() {
    local snapshot="$1" entry output

    if command -v sha256sum >/dev/null 2>&1; then
        output=$(
            set -o pipefail
            {
                local i
                for i in "${!__phb_modules[@]}"; do
                    entry="${__phb_modules[$i]}"
                    command cat -- "$snapshot/$entry" || exit 1
                    if ((i + 1 < ${#__phb_modules[@]})); then
                        printf '\n' || exit 1
                    fi
                done
            } | sha256sum | awk '{print $1}'
        ) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        output=$(
            set -o pipefail
            {
                local i
                for i in "${!__phb_modules[@]}"; do
                    entry="${__phb_modules[$i]}"
                    command cat -- "$snapshot/$entry" || exit 1
                    if ((i + 1 < ${#__phb_modules[@]})); then
                        printf '\n' || exit 1
                    fi
                done
            } | shasum -a 256 | awk '{print $1}'
        ) || return 1
    elif command -v openssl >/dev/null 2>&1; then
        output=$(
            set -o pipefail
            {
                local i
                for i in "${!__phb_modules[@]}"; do
                    entry="${__phb_modules[$i]}"
                    command cat -- "$snapshot/$entry" || exit 1
                    if ((i + 1 < ${#__phb_modules[@]})); then
                        printf '\n' || exit 1
                    fi
                done
            } | openssl dgst -sha256
        ) || return 1
        output="${output##*= }"
    else
        __phb_error "sha256sum, shasum, or openssl is required"
        return 1
    fi

    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$output" || return 1
}

__phb_reject_nul() {
    local file="$1" label="$2" total_bytes non_nul_bytes
    total_bytes=$(wc -c < "$file" | tr -d '[:space:]') || return 1
    non_nul_bytes=$(LC_ALL=C tr -d '\000' < "$file" | wc -c | tr -d '[:space:]') || return 1
    [[ "$non_nul_bytes" == "$total_bytes" ]] || {
        __phb_error "$label contains a NUL byte"
        return 1
    }
}

__phb_cleanup_unpublished_tmp() {
    local path="$1" expected_id="$2" current_id owner
    [[ -n "$path" && -n "$expected_id" ]] || return 0
    case "$path" in
        "${__phb_tmp_parent%/}"/proxy-hub.bootstrap.*)
            if [[ -d "$path" && ! -L "$path" ]]; then
                current_id=$(stat -c '%d:%i' "$path" 2>/dev/null) || current_id=""
                owner=$(stat -c '%u' "$path" 2>/dev/null) || owner=""
                if [[ "$current_id" == "$expected_id" && "$owner" == "$EUID" ]]; then
                    rm -rf -- "$path" 2>/dev/null || true
                fi
            fi
            ;;
    esac
}

__phb_cleanup_tmp() {
    local path="${__phb_tmp_root:-}" current_id owner
    [[ -n "$path" ]] || return 0
    case "$path" in
        "${__phb_tmp_parent%/}"/proxy-hub.bootstrap.*)
            if [[ -d "$path" && ! -L "$path" ]]; then
                current_id=$(stat -c '%d:%i' "$path" 2>/dev/null) || current_id=""
                owner=$(stat -c '%u' "$path" 2>/dev/null) || owner=""
                if [[ -n "$__phb_tmp_root_id" && "$current_id" == "$__phb_tmp_root_id" && "$owner" == "$EUID" ]]; then
                    rm -rf -- "$path" 2>/dev/null || true
                fi
            fi
            ;;
    esac
    __phb_tmp_root=""
    __phb_tmp_root_id=""
}

__phb_exit_trap() {
    local status="$1"
    trap - EXIT INT TERM
    __phb_cleanup_tmp || true
    exit "$status"
}

__phb_signal_trap() {
    local signal="$1" fallback_status="$2"
    trap - EXIT INT TERM
    __phb_cleanup_tmp || true
    kill -s "$signal" "$$" 2>/dev/null || exit "$fallback_status"
    exit "$fallback_status"
}

trap '__phb_exit_trap $?' EXIT
trap '__phb_signal_trap INT 130' INT
trap '__phb_signal_trap TERM 143' TERM

__phb_prepare_tmp_parent() {
    local candidate="${TMPDIR:-/tmp}" resolved owner mode

    [[ "$candidate" != *$'\n'* && "$candidate" != *$'\r'* ]] || return 1
    [[ -d "$candidate" && ! -L "$candidate" && -w "$candidate" ]] || {
        __phb_error "TMPDIR is not a writable, real directory: $candidate"
        return 1
    }
    resolved=$(cd -P -- "$candidate" 2>/dev/null && pwd) || return 1
    owner=$(stat -c '%u' "$resolved" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$resolved" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]+$ ]] || return 1

    if [[ "$owner" == "$EUID" ]] && (( (8#$mode & 022) == 0 )); then
        :
    elif [[ "$owner" == "0" ]] && (( (8#$mode & 01000) != 0 )); then
        :
    else
        __phb_error "refusing unsafe TMPDIR parent: $resolved"
        return 1
    fi
    __phb_tmp_parent="$resolved"
}

__phb_make_tmp() {
    local publication pending_signal rc=1 saved_hup saved_int saved_term
    local -a published=()
    __phb_prepare_tmp_parent || return 1

    __phb_tmp_signal_pending=""
    saved_hup=$(trap -p HUP || true)
    saved_int=$(trap -p INT || true)
    saved_term=$(trap -p TERM || true)
    trap '__phb_tmp_signal_pending=HUP' HUP
    trap '__phb_tmp_signal_pending=INT' INT
    trap '__phb_tmp_signal_pending=TERM' TERM

    if publication=$(
        local created_path="" created_id="" owner="" child_status=0 child_cleanup_armed=0
        trap '' HUP INT TERM
        created_path=$(mktemp -d "${__phb_tmp_parent%/}/proxy-hub.bootstrap.XXXXXXXX") || exit 1
        if [[ ! -d "$created_path" || -L "$created_path" ]]; then
            exit 1
        fi
        created_id=$(stat -c '%d:%i' "$created_path" 2>/dev/null) || exit 1
        child_cleanup_armed=1
        trap 'child_status=$?; if ((child_cleanup_armed == 1)); then __phb_cleanup_unpublished_tmp "$created_path" "$created_id"; fi; trap - EXIT; exit "$child_status"' EXIT
        owner=$(stat -c '%u' "$created_path" 2>/dev/null) || exit 1
        [[ "$owner" == "$EUID" ]] || exit 1
        chmod 700 "$created_path" || exit 1
        printf '%s\n%s\n' "$created_path" "$created_id" || exit 1
        child_cleanup_armed=0
        trap - EXIT
    ); then
        mapfile -t published <<< "$publication"
        if [[ ${#published[@]} -eq 2 && -n "${published[0]}" && -n "${published[1]}" ]]; then
            __phb_tmp_root="${published[0]}"
            __phb_tmp_root_id="${published[1]}"
            rc=0
        fi
    fi

    if [[ -n "$saved_hup" ]]; then eval "$saved_hup"; else trap - HUP; fi
    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    pending_signal="$__phb_tmp_signal_pending"
    __phb_tmp_signal_pending=""
    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || true
    fi
    ((rc == 0)) || __phb_error "cannot create a private bootstrap directory"
    return "$rc"
}

__phb_resolve_entry() {
    local source_path="${BASH_SOURCE[0]}" source_dir target
    [[ "$source_path" != /dev/fd/* && "$source_path" != /proc/*/fd/* ]] || return 1

    while [[ -L "$source_path" ]]; do
        source_dir=$(cd -P "$(dirname "$source_path")" 2>/dev/null && pwd) || return 1
        target=$(readlink "$source_path") || return 1
        if [[ "$target" == /* ]]; then
            source_path="$target"
        else
            source_path="$source_dir/$target"
        fi
    done

    [[ -f "$source_path" ]] || return 1
    source_dir=$(cd -P "$(dirname "$source_path")" 2>/dev/null && pwd) || return 1
    __phb_entry_file="$source_dir/$(basename "$source_path")"
    __phb_local_root="$source_dir"
}

__phb_check_source_inventory() {
    local lib_dir="$1" entry expected_count actual_count

    actual_count=$(
        local -a inventory_entries=()
        shopt -s nullglob dotglob
        inventory_entries=("$lib_dir"/*)
        printf '%s\n' "${#inventory_entries[@]}"
    ) || return 1
    expected_count=$((${#__phb_modules[@]} + 1))
    [[ "$actual_count" -eq "$expected_count" ]] || {
        __phb_error "unexpected file inventory in $lib_dir"
        return 1
    }

    [[ -f "$lib_dir/manifest.sha256" && ! -L "$lib_dir/manifest.sha256" ]] || return 1
    for entry in "${__phb_modules[@]}"; do
        [[ -f "$lib_dir/$entry" && ! -L "$lib_dir/$entry" ]] || {
            __phb_error "missing or unsafe local module: $entry"
            return 1
        }
    done
}

__phb_has_local_footprint() {
    local lib_dir="$1" entry
    [[ -d "$lib_dir" ]] || return 1
    [[ -e "$lib_dir/manifest.sha256" || -L "$lib_dir/manifest.sha256" ]] && return 0
    for entry in "${__phb_modules[@]}"; do
        [[ -e "$lib_dir/$entry" || -L "$lib_dir/$entry" ]] && return 0
    done
    return 1
}

__phb_copy_local_snapshot() {
    local lib_dir="$1" snapshot="$__phb_tmp_root/snapshot" entry
    mkdir -m 700 "$snapshot" || return 1
    __phb_check_source_inventory "$lib_dir" || return 1

    cp -P -- "$lib_dir/manifest.sha256" "$snapshot/manifest.sha256" || return 1
    for entry in "${__phb_modules[@]}"; do
        cp -P -- "$lib_dir/$entry" "$snapshot/$entry" || return 1
    done

    [[ -f "$snapshot/manifest.sha256" && ! -L "$snapshot/manifest.sha256" ]] || return 1
    chmod 600 "$snapshot/manifest.sha256" || return 1
    for entry in "${__phb_modules[@]}"; do
        [[ -f "$snapshot/$entry" && ! -L "$snapshot/$entry" ]] || {
            __phb_error "snapshot contains an unsafe module: $entry"
            return 1
        }
        chmod 600 "$snapshot/$entry" || return 1
    done
}

__phb_validate_local_snapshot() {
    local snapshot="$__phb_tmp_root/snapshot"
    local manifest="$snapshot/manifest.sha256"
    local canonical="$__phb_tmp_root/manifest.canonical"
    local body="$__phb_tmp_root/runtime.body"
    local manifest_build actual_build line digest name actual_digest
    local actual_body_bytes actual_body_sha expected_body_bytes=0 expected_body_sha module_bytes
    local i last_byte
    local -a lines=() digests=()

    __phb_reject_nul "$manifest" "local manifest" || return 1
    last_byte=$(tail -c 1 "$manifest" | od -An -tu1 | tr -d '[:space:]') || return 1
    [[ "$last_byte" == "10" ]] || {
        __phb_error "local manifest is missing its final newline"
        return 1
    }
    mapfile -t lines < "$manifest" || return 1
    [[ ${#lines[@]} -eq $((${#__phb_modules[@]} + 4)) ]] || {
        __phb_error "invalid local manifest length"
        return 1
    }
    [[ "${lines[0]}" == '# proxy-hub-manifest-v1' ]] || return 1
    [[ "${lines[1]}" == '# api=1' ]] || return 1
    [[ "${lines[2]}" =~ ^#[[:space:]]build-id=([0-9a-f]{64})$ ]] || return 1
    manifest_build="${BASH_REMATCH[1]}"
    [[ "${lines[-1]}" == '# proxy-hub-manifest-end-v1' ]] || return 1

    : > "$canonical" || return 1
    : > "$body" || return 1
    printf 'api=1\n' >> "$canonical" || return 1
    for i in "${!__phb_modules[@]}"; do
        line="${lines[$((i + 3))]}"
        [[ "$line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]([A-Za-z0-9_][A-Za-z0-9_.-]*)$ ]] || {
            __phb_error "malformed manifest record"
            return 1
        }
        digest="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        digests+=("$digest")
        [[ "$name" == "${__phb_modules[$i]}" ]] || {
            __phb_error "unexpected module order: $name"
            return 1
        }
        __phb_reject_nul "$snapshot/$name" "module $name" || return 1
        actual_digest=$(__phb_hash_file "$snapshot/$name") || return 1
        [[ "$actual_digest" == "$digest" ]] || {
            __phb_error "module checksum mismatch: $name"
            return 1
        }
        bash -n "$snapshot/$name" || {
            __phb_error "module syntax check failed: $name"
            return 1
        }
        module_bytes=$(wc -c < "$snapshot/$name" | tr -d '[:space:]') || return 1
        [[ "$module_bytes" =~ ^[0-9]+$ ]] || return 1
        expected_body_bytes=$((expected_body_bytes + module_bytes))

        printf '%s\0%s\n' "$name" "$digest" >> "$canonical" || return 1
        command cat -- "$snapshot/$name" >> "$body" || {
            __phb_error "failed to assemble local runtime: $name"
            return 1
        }
        if ((i + 1 < ${#__phb_modules[@]})); then
            printf '\n' >> "$body" || return 1
            expected_body_bytes=$((expected_body_bytes + 1))
        fi
    done

    actual_build=$(__phb_hash_file "$canonical") || return 1
    [[ "$actual_build" == "$manifest_build" ]] || {
        __phb_error "local manifest build-id mismatch"
        return 1
    }
    actual_body_bytes=$(wc -c < "$body" | tr -d '[:space:]') || return 1
    [[ "$actual_body_bytes" =~ ^[0-9]+$ && "$actual_body_bytes" -eq "$expected_body_bytes" ]] || {
        __phb_error "assembled local runtime length mismatch"
        return 1
    }

    # Re-read the immutable snapshot as a stream and bind the assembled file to
    # that exact concatenation.  Individual module digests are checked again so
    # a complete, syntactically-valid module omission cannot pass preflight.
    for i in "${!__phb_modules[@]}"; do
        name="${__phb_modules[$i]}"
        actual_digest=$(__phb_hash_file "$snapshot/$name") || return 1
        [[ "$actual_digest" == "${digests[$i]}" ]] || {
            __phb_error "module changed during local assembly: $name"
            return 1
        }
    done
    expected_body_sha=$(__phb_hash_module_stream "$snapshot") || return 1
    actual_body_sha=$(__phb_hash_file "$body") || return 1
    [[ "$actual_body_sha" == "$expected_body_sha" ]] || {
        __phb_error "assembled local runtime checksum mismatch"
        return 1
    }
    __phb_reject_nul "$body" "assembled local runtime" || return 1
    bash -n "$body" || {
        __phb_error "assembled local runtime failed syntax validation"
        return 1
    }
    chmod 400 "$body" || return 1
    __phb_runtime_file="$body"
    __phb_expected_runtime_bytes="$expected_body_bytes"
    __phb_expected_runtime_sha="$expected_body_sha"
}

__phb_prepare_local() {
    local lib_dir="$__phb_local_root/lib"
    __phb_make_tmp || return 1
    __phb_copy_local_snapshot "$lib_dir" || return 1
    __phb_validate_local_snapshot || return 1
}

__phb_validate_ref() {
    local ref="$1"
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    [[ "$ref" != /* && "$ref" != */ && "$ref" != *..* && "$ref" != *//* ]]
}

__phb_prepare_remote() {
    local ref="${PROXY_HUB_REF:-main}"
    local bundle header body reconstructed reconstructed_header reconstructed_body trailer_file
    local url total_bytes last_byte trailer_bytes header_bytes header_sha body_bytes body_sha build_id
    local actual_header_sha actual_body_sha reconstructed_bytes reconstructed_header_sha reconstructed_body_sha
    local -a trailer=()

    __phb_validate_ref "$ref" || {
        __phb_error "invalid PROXY_HUB_REF: $ref"
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        __phb_error "curl is required for standalone/remote execution"
        return 1
    }
    __phb_make_tmp || return 1

    bundle="$__phb_tmp_root/proxy-hub.bundle.sh"
    header="$__phb_tmp_root/header"
    body="$__phb_tmp_root/runtime.body"
    reconstructed="$__phb_tmp_root/runtime.full"
    url="https://raw.githubusercontent.com/Banezzz/proxy-hub/${ref}/dist/proxy-hub.bundle.sh"

    curl -q --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 3 \
        --fail --silent --show-error --location --output "$bundle" -- "$url" || {
        __phb_error "failed to download runtime bundle for ref '$ref'"
        return 1
    }
    [[ -f "$bundle" && ! -L "$bundle" ]] || return 1
    chmod 600 "$bundle" || return 1
    total_bytes=$(wc -c < "$bundle" | tr -d '[:space:]') || return 1
    last_byte=$(tail -c 1 "$bundle" | od -An -tu1 | tr -d '[:space:]') || return 1
    [[ "$last_byte" == "10" ]] || {
        __phb_error "runtime bundle is missing its final newline"
        return 1
    }
    __phb_reject_nul "$bundle" "runtime bundle" || return 1

    trailer_file="$__phb_tmp_root/trailer"
    tail -n 6 "$bundle" > "$trailer_file" || return 1
    mapfile -t trailer < "$trailer_file" || return 1
    [[ ${#trailer[@]} -eq 6 ]] || return 1
    [[ "${trailer[0]}" == '# proxy-hub-bundle-manifest-v1' ]] || return 1
    [[ "${trailer[1]}" =~ ^#[[:space:]]header-bytes=([0-9]+)[[:space:]]header-sha256=([0-9a-f]{64})$ ]] || return 1
    header_bytes="${BASH_REMATCH[1]}"
    header_sha="${BASH_REMATCH[2]}"
    [[ "${trailer[2]}" =~ ^#[[:space:]]body-bytes=([0-9]+)[[:space:]]body-sha256=([0-9a-f]{64})$ ]] || return 1
    body_bytes="${BASH_REMATCH[1]}"
    body_sha="${BASH_REMATCH[2]}"
    [[ "${trailer[3]}" =~ ^#[[:space:]]build-id=([0-9a-f]{64})$ ]] || return 1
    build_id="${BASH_REMATCH[1]}"
    [[ "${trailer[4]}" == "# module-count=${#__phb_modules[@]}" ]] || return 1
    [[ "${trailer[5]}" == '# proxy-hub-bundle-end-v1' ]] || return 1
    [[ "$body_sha" == "$build_id" ]] || {
        __phb_error "runtime bundle build-id mismatch"
        return 1
    }
    [[ "$header_bytes" == "$__phb_expected_header_bytes" && "$header_sha" == "$__phb_expected_header_sha" ]] || {
        __phb_error "runtime bundle header contract mismatch"
        return 1
    }

    trailer_bytes=$(wc -c < "$trailer_file" | tr -d '[:space:]') || return 1
    [[ "$total_bytes" -eq $((header_bytes + body_bytes + trailer_bytes)) ]] || {
        __phb_error "runtime bundle length mismatch"
        return 1
    }

    dd if="$bundle" of="$header" bs=1 count="$header_bytes" 2>/dev/null || return 1
    dd if="$bundle" of="$body" bs=1 skip="$header_bytes" count="$body_bytes" 2>/dev/null || return 1
    [[ "$(wc -c < "$header" | tr -d '[:space:]')" == "$header_bytes" ]] || return 1
    [[ "$(wc -c < "$body" | tr -d '[:space:]')" == "$body_bytes" ]] || return 1
    actual_header_sha=$(__phb_hash_file "$header") || return 1
    actual_body_sha=$(__phb_hash_file "$body") || return 1
    [[ "$actual_header_sha" == "$header_sha" && "$actual_body_sha" == "$body_sha" ]] || {
        __phb_error "runtime bundle checksum mismatch"
        return 1
    }

    command cat -- "$header" "$body" > "$reconstructed" || {
        __phb_error "failed to reconstruct runtime bundle for syntax validation"
        return 1
    }
    reconstructed_bytes=$(wc -c < "$reconstructed" | tr -d '[:space:]') || return 1
    [[ "$reconstructed_bytes" =~ ^[0-9]+$ &&
       "$reconstructed_bytes" -eq $((header_bytes + body_bytes)) ]] || {
        __phb_error "runtime syntax reconstruction length mismatch"
        return 1
    }
    reconstructed_header="$__phb_tmp_root/reconstructed.header"
    reconstructed_body="$__phb_tmp_root/reconstructed.body"
    dd if="$reconstructed" of="$reconstructed_header" bs=1 count="$header_bytes" 2>/dev/null || return 1
    dd if="$reconstructed" of="$reconstructed_body" bs=1 skip="$header_bytes" count="$body_bytes" 2>/dev/null || return 1
    [[ "$(wc -c < "$reconstructed_header" | tr -d '[:space:]')" == "$header_bytes" ]] || return 1
    [[ "$(wc -c < "$reconstructed_body" | tr -d '[:space:]')" == "$body_bytes" ]] || return 1
    reconstructed_header_sha=$(__phb_hash_file "$reconstructed_header") || return 1
    reconstructed_body_sha=$(__phb_hash_file "$reconstructed_body") || return 1
    [[ "$reconstructed_header_sha" == "$header_sha" &&
       "$reconstructed_body_sha" == "$body_sha" ]] || {
        __phb_error "runtime syntax reconstruction checksum mismatch"
        return 1
    }
    bash -n "$reconstructed" || {
        __phb_error "runtime bundle failed syntax validation"
        return 1
    }
    chmod 400 "$body" || return 1
    __phb_runtime_file="$body"
    __phb_expected_runtime_bytes="$body_bytes"
    __phb_expected_runtime_sha="$body_sha"
}

__phb_open_verified_runtime() {
    local fd_path actual_bytes actual_sha

    [[ "$__phb_expected_runtime_bytes" =~ ^[0-9]+$ &&
       "$__phb_expected_runtime_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    exec {__phb_runtime_fd}<"$__phb_runtime_file" || return 1
    fd_path="/dev/fd/$__phb_runtime_fd"
    actual_bytes=$(wc -c < "$fd_path" | tr -d '[:space:]') || {
        exec {__phb_runtime_fd}<&- 2>/dev/null || true
        return 1
    }
    actual_sha=$(__phb_hash_file "$fd_path") || {
        exec {__phb_runtime_fd}<&- 2>/dev/null || true
        return 1
    }
    [[ "$actual_bytes" == "$__phb_expected_runtime_bytes" &&
       "$actual_sha" == "$__phb_expected_runtime_sha" ]] || {
        __phb_error "runtime changed between validation and execution"
        exec {__phb_runtime_fd}<&- 2>/dev/null || true
        return 1
    }
}

if __phb_resolve_entry && __phb_has_local_footprint "$__phb_local_root/lib"; then
    __phb_prepare_local || {
        __phb_error "local module preflight failed"
        exit 1
    }
else
    __phb_prepare_remote || {
        __phb_error "remote bundle preflight failed"
        exit 1
    }
fi

__phb_open_verified_runtime || {
    __phb_error "cannot bind the validated runtime for execution"
    exit 1
}

__phb_cleanup_tmp || true
trap - EXIT INT TERM

unset __phb_modules __phb_tmp_root __phb_tmp_root_id __phb_tmp_signal_pending __phb_tmp_parent __phb_runtime_file
unset __phb_expected_runtime_bytes __phb_expected_runtime_sha
unset __phb_entry_file __phb_local_root __phb_expected_header_bytes __phb_expected_header_sha
unset -f __phb_error __phb_hash_file __phb_hash_module_stream __phb_reject_nul __phb_cleanup_tmp __phb_exit_trap __phb_signal_trap
unset -f __phb_prepare_tmp_parent __phb_make_tmp __phb_resolve_entry __phb_check_source_inventory
unset -f __phb_has_local_footprint __phb_copy_local_snapshot __phb_validate_local_snapshot __phb_prepare_local
unset -f __phb_validate_ref __phb_prepare_remote __phb_open_verified_runtime

source "/dev/fd/$__phb_runtime_fd" "$@"
__phb_return_status=$?
exec {__phb_runtime_fd}<&- 2>/dev/null || true
unset __phb_runtime_fd
return "$__phb_return_status" 2>/dev/null || exit "$__phb_return_status"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB_DIR="$ROOT_DIR/lib"
MANIFEST_FILE="$LIB_DIR/manifest.sha256"
BUNDLE_FILE="$ROOT_DIR/dist/proxy-hub.bundle.sh"
MODULES=(
    00_security_state.sh
    10_runtime_platform_ui.sh
    20_installers_restart.sh
    30_provision_network.sh
    40_config_share.sh
    50_node_commands.sh
    60_system_tools.sh
    70_ports_logs.sh
    80_timesync.sh
    90_main.sh
)

hash_file() {
    local file="$1" output
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        output=$(openssl dgst -sha256 "$file")
        printf '%s\n' "${output##*= }"
    else
        echo "error: sha256sum, shasum, or openssl is required" >&2
        return 1
    fi
}

reject_nul() {
    local file="$1" label="$2" total_bytes non_nul_bytes
    total_bytes=$(wc -c < "$file" | tr -d '[:space:]')
    non_nul_bytes=$(LC_ALL=C tr -d '\000' < "$file" | wc -c | tr -d '[:space:]')
    [[ "$non_nul_bytes" == "$total_bytes" ]] || {
        echo "error: $label contains a NUL byte" >&2
        return 1
    }
}

BUILD_TMP_ROOT=""
BUILD_TMP_ROOT_ID=""
BUILD_TMP_PARENT="${TMPDIR:-/tmp}"
BUILD_TMP_SIGNAL_PENDING=""
MANIFEST_TXN_ROOT=""
MANIFEST_TXN_ROOT_ID=""
BUNDLE_TXN_ROOT=""
BUNDLE_TXN_ROOT_ID=""
MANIFEST_INSTALLED=0
BUNDLE_INSTALLED=0
MANIFEST_NEW_ID=""
MANIFEST_OLD_ID=""
MANIFEST_OLD_EXISTS=0
BUNDLE_NEW_ID=""
BUNDLE_OLD_ID=""
BUNDLE_OLD_EXISTS=0
TXN_SAVED_INT=""
TXN_SAVED_TERM=""
TXN_SAVED_HUP=""
RELEASE_LOCK_PATH="$ROOT_DIR/.proxy-hub.release.lock"
RELEASE_LOCK_ID=""
RELEASE_LOCK_PAYLOAD=""
RELEASE_LOCK_TOKEN=""
RELEASE_LOCK_HELD=0
RELEASE_LOCK_SAFE_TO_RELEASE=1

process_identity() {
    local pid="$1" stat_line rest
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    rest="${stat_line##*) }"
    set -- $rest
    (($# >= 20)) || return 1
    [[ "$1" != Z && "$1" != X ]] || return 1
    printf '%s\n' "${20}"
}

release_lock_identity() {
    local path="$1" owner identity kind
    [[ -L "$path" ]] || return 1
    owner=$(stat -c '%u' -- "$path" 2>/dev/null) || return 1
    identity=$(stat -c '%d:%i' -- "$path" 2>/dev/null) || return 1
    kind=$(stat -c '%F' -- "$path" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$kind" == "symbolic link" ]] || return 1
    printf '%s\n' "$identity"
}

release_lock_intact() {
    local identity payload
    ((RELEASE_LOCK_HELD == 1)) || return 1
    identity=$(release_lock_identity "$RELEASE_LOCK_PATH" 2>/dev/null) || return 1
    payload=$(readlink -- "$RELEASE_LOCK_PATH" 2>/dev/null) || return 1
    [[ "$identity" == "$RELEASE_LOCK_ID" && "$payload" == "$RELEASE_LOCK_PAYLOAD" ]]
}

release_lock_owner_is_live() {
    local payload="$1" prefix uid pid start token actual_start
    IFS=: read -r prefix uid pid start token <<< "$payload"
    if [[ "$prefix" == "proxy-hub-release-uncertain-v1" ]]; then
        return 3
    fi
    [[ "$prefix" == "proxy-hub-release-v1" && "$uid" == "$EUID" ]] || return 2
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^[0-9]+$ && \
       "$token" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
    actual_start=$(process_identity "$pid" 2>/dev/null) || return 1
    [[ "$actual_start" == "$start" ]]
}

reclaim_stale_release_lock() {
    local observed_id="$1" observed_payload="$2" quarantine quarantine_id quarantine_payload
    quarantine="$ROOT_DIR/.proxy-hub.release.stale.${RELEASE_LOCK_TOKEN}"
    [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
    mv -T -- "$RELEASE_LOCK_PATH" "$quarantine" || return 1
    quarantine_id=$(release_lock_identity "$quarantine" 2>/dev/null) || {
        echo "error: release lock identity changed during stale-lock quarantine; preserving $quarantine" >&2
        return 1
    }
    quarantine_payload=$(readlink -- "$quarantine" 2>/dev/null) || return 1
    if [[ "$quarantine_id" != "$observed_id" || "$quarantine_payload" != "$observed_payload" ]]; then
        echo "error: release lock was replaced during stale-lock quarantine; preserving $quarantine" >&2
        return 1
    fi
    rm -f -- "$quarantine" || return 1
    [[ ! -e "$quarantine" && ! -L "$quarantine" ]]
}

acquire_release_lock() {
    local self_start candidate_payload observed_id observed_payload owner_rc attempt
    self_start=$(process_identity "$$") || {
        echo "error: cannot identify builder process for release lock" >&2
        return 1
    }
    RELEASE_LOCK_TOKEN="$$-${self_start}-${RANDOM}-${RANDOM}"
    candidate_payload="proxy-hub-release-v1:${EUID}:$$:${self_start}:${RELEASE_LOCK_TOKEN}"

    for attempt in 1 2; do
        if ln -s -- "$candidate_payload" "$RELEASE_LOCK_PATH" 2>/dev/null; then
            RELEASE_LOCK_ID=$(release_lock_identity "$RELEASE_LOCK_PATH" 2>/dev/null) || {
                echo "error: created release lock has an unsafe identity" >&2
                return 1
            }
            RELEASE_LOCK_PAYLOAD=$(readlink -- "$RELEASE_LOCK_PATH" 2>/dev/null) || return 1
            [[ "$RELEASE_LOCK_PAYLOAD" == "$candidate_payload" ]] || {
                echo "error: release lock was replaced while ownership was published" >&2
                return 1
            }
            RELEASE_LOCK_HELD=1
            RELEASE_LOCK_SAFE_TO_RELEASE=1
            release_lock_intact || {
                echo "error: release lock identity changed immediately after acquisition" >&2
                return 1
            }
            return 0
        fi

        observed_id=$(release_lock_identity "$RELEASE_LOCK_PATH" 2>/dev/null) || {
            echo "error: refusing unsafe or incomplete release lock: $RELEASE_LOCK_PATH" >&2
            return 1
        }
        observed_payload=$(readlink -- "$RELEASE_LOCK_PATH" 2>/dev/null) || return 1
        [[ "$(release_lock_identity "$RELEASE_LOCK_PATH" 2>/dev/null || true)" == "$observed_id" ]] || {
            echo "error: release lock identity changed while inspected" >&2
            return 1
        }
        owner_rc=0
        release_lock_owner_is_live "$observed_payload" || owner_rc=$?
        case "$owner_rc" in
            0)
                echo "error: another proxy-hub bundle publisher holds the release lock" >&2
                return 1
                ;;
            1)
                reclaim_stale_release_lock "$observed_id" "$observed_payload" || return 1
                ;;
            3)
                echo "error: a previous publisher left an uncertain release lock; manual recovery is required" >&2
                return 1
                ;;
            *)
                echo "error: refusing malformed release lock metadata" >&2
                return 1
                ;;
        esac
    done
    echo "error: could not acquire release lock after stale-lock recovery" >&2
    return 1
}

mark_release_lock_uncertain() {
    local transition payload transition_id current_id
    ((RELEASE_LOCK_HELD == 1 && RELEASE_LOCK_SAFE_TO_RELEASE == 1)) || return 1
    release_lock_intact || return 1
    transition="$ROOT_DIR/.proxy-hub.release.transition.${RELEASE_LOCK_TOKEN}"
    payload="proxy-hub-release-uncertain-v1:${EUID}:$$:$(process_identity "$$"):${RELEASE_LOCK_TOKEN}"
    [[ ! -e "$transition" && ! -L "$transition" ]] || return 1
    ln -s -- "$payload" "$transition" || return 1
    transition_id=$(release_lock_identity "$transition" 2>/dev/null) || {
        rm -f -- "$transition" 2>/dev/null || true
        return 1
    }
    [[ "$(readlink -- "$transition" 2>/dev/null || true)" == "$payload" ]] || return 1
    release_lock_intact || {
        rm -f -- "$transition" 2>/dev/null || true
        return 1
    }

    # From this point onward an abnormal exit must retain a non-reclaimable
    # marker until rollback/commit and transaction disposal are both verified.
    RELEASE_LOCK_SAFE_TO_RELEASE=0
    if ! mv -Tf -- "$transition" "$RELEASE_LOCK_PATH"; then
        if release_lock_intact; then
            RELEASE_LOCK_SAFE_TO_RELEASE=1
        fi
        rm -f -- "$transition" 2>/dev/null || true
        return 1
    fi
    current_id=$(release_lock_identity "$RELEASE_LOCK_PATH" 2>/dev/null) || return 1
    [[ "$current_id" == "$transition_id" && \
       "$(readlink -- "$RELEASE_LOCK_PATH" 2>/dev/null || true)" == "$payload" ]] || return 1
    RELEASE_LOCK_ID="$current_id"
    RELEASE_LOCK_PAYLOAD="$payload"
    release_lock_intact
}

release_release_lock() {
    local quarantine quarantine_id quarantine_payload rc=0
    ((RELEASE_LOCK_HELD == 1)) || return 0
    ((RELEASE_LOCK_SAFE_TO_RELEASE == 1)) || {
        echo "error: retaining uncertain release lock because artifact state was not verified" >&2
        return 1
    }
    release_lock_intact || {
        echo "error: refusing to remove a replaced release lock" >&2
        return 1
    }
    quarantine="$ROOT_DIR/.proxy-hub.release.done.${RELEASE_LOCK_TOKEN}"
    [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
    mv -T -- "$RELEASE_LOCK_PATH" "$quarantine" || return 1
    quarantine_id=$(release_lock_identity "$quarantine" 2>/dev/null) || rc=1
    quarantine_payload=$(readlink -- "$quarantine" 2>/dev/null) || rc=1
    if ((rc != 0)) || [[ "$quarantine_id" != "$RELEASE_LOCK_ID" || "$quarantine_payload" != "$RELEASE_LOCK_PAYLOAD" ]]; then
        echo "error: release lock identity changed during release; preserving $quarantine" >&2
        return 1
    fi
    rm -f -- "$quarantine" || return 1
    RELEASE_LOCK_HELD=0
    RELEASE_LOCK_SAFE_TO_RELEASE=1
    RELEASE_LOCK_ID=""
    RELEASE_LOCK_PAYLOAD=""
    [[ ! -e "$quarantine" && ! -L "$quarantine" ]]
}

prepare_tmp_parent() {
    local candidate="${TMPDIR:-/tmp}" resolved owner mode
    [[ "$candidate" != *$'\n'* && "$candidate" != *$'\r'* ]] || return 1
    [[ -d "$candidate" && ! -L "$candidate" && -w "$candidate" ]] || {
        echo "error: TMPDIR is not a writable, real directory: $candidate" >&2
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
        echo "error: refusing unsafe TMPDIR parent: $resolved" >&2
        return 1
    fi
    BUILD_TMP_PARENT="$resolved"
}

publish_build_tmp() {
    local publication pending_signal rc=1 saved_hup saved_int saved_term
    local -a published=()

    BUILD_TMP_SIGNAL_PENDING=""
    saved_int=$(trap -p INT || true)
    saved_term=$(trap -p TERM || true)
    saved_hup=$(trap -p HUP || true)
    trap 'BUILD_TMP_SIGNAL_PENDING=INT' INT
    trap 'BUILD_TMP_SIGNAL_PENDING=TERM' TERM
    trap 'BUILD_TMP_SIGNAL_PENDING=HUP' HUP

    if publication=$(
        local created_path="" created_id="" owner="" child_status=0 child_cleanup_armed=0
        trap '' INT TERM HUP
        created_path=$(mktemp -d "${BUILD_TMP_PARENT%/}/proxy-hub.build.XXXXXXXX") || exit 1
        [[ -d "$created_path" && ! -L "$created_path" ]] || exit 1
        created_id=$(stat -c '%d:%i' "$created_path" 2>/dev/null) || exit 1
        child_cleanup_armed=1
        trap 'child_status=$?; if ((child_cleanup_armed == 1)); then cleanup_private_dir "$created_path" "$created_id" "$BUILD_TMP_PARENT" "proxy-hub.build."; fi; trap - EXIT; exit "$child_status"' EXIT
        owner=$(stat -c '%u' "$created_path" 2>/dev/null) || exit 1
        [[ "$owner" == "$EUID" ]] || exit 1
        chmod 700 "$created_path" || exit 1
        printf '%s\n%s\n' "$created_path" "$created_id" || exit 1
        child_cleanup_armed=0
        trap - EXIT
    ); then
        mapfile -t published <<< "$publication"
        if [[ ${#published[@]} -eq 2 && -n "${published[0]}" && -n "${published[1]}" ]]; then
            BUILD_TMP_ROOT="${published[0]}"
            BUILD_TMP_ROOT_ID="${published[1]}"
            rc=0
        fi
    fi

    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    if [[ -n "$saved_hup" ]]; then eval "$saved_hup"; else trap - HUP; fi
    pending_signal="$BUILD_TMP_SIGNAL_PENDING"
    BUILD_TMP_SIGNAL_PENDING=""
    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || true
    fi
    return "$rc"
}

publish_transaction_dir() {
    local parent="$1" prefix="$2" path_var="$3" id_var="$4"
    local publication pending_signal rc=1 saved_hup saved_int saved_term
    local -a published=()

    [[ -d "$parent" && ! -L "$parent" && -w "$parent" ]] || {
        echo "error: unsafe transaction parent: $parent" >&2
        return 1
    }

    BUILD_TMP_SIGNAL_PENDING=""
    saved_int=$(trap -p INT || true)
    saved_term=$(trap -p TERM || true)
    saved_hup=$(trap -p HUP || true)
    trap 'BUILD_TMP_SIGNAL_PENDING=INT' INT
    trap 'BUILD_TMP_SIGNAL_PENDING=TERM' TERM
    trap 'BUILD_TMP_SIGNAL_PENDING=HUP' HUP

    if publication=$(
        local created_path="" created_id="" owner="" child_status=0 child_cleanup_armed=0
        trap '' INT TERM HUP
        created_path=$(mktemp -d "${parent%/}/${prefix}XXXXXXXX") || exit 1
        [[ -d "$created_path" && ! -L "$created_path" ]] || exit 1
        created_id=$(stat -c '%d:%i' "$created_path" 2>/dev/null) || exit 1
        child_cleanup_armed=1
        trap 'child_status=$?; if ((child_cleanup_armed == 1)); then cleanup_private_dir "$created_path" "$created_id" "$parent" "$prefix"; fi; trap - EXIT; exit "$child_status"' EXIT
        owner=$(stat -c '%u' "$created_path" 2>/dev/null) || exit 1
        [[ "$owner" == "$EUID" ]] || exit 1
        chmod 700 "$created_path" || exit 1
        printf '%s\n%s\n' "$created_path" "$created_id" || exit 1
        child_cleanup_armed=0
        trap - EXIT
    ); then
        mapfile -t published <<< "$publication"
        if [[ ${#published[@]} -eq 2 && -n "${published[0]}" && -n "${published[1]}" ]]; then
            printf -v "$path_var" '%s' "${published[0]}"
            printf -v "$id_var" '%s' "${published[1]}"
            rc=0
        fi
    fi

    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    if [[ -n "$saved_hup" ]]; then eval "$saved_hup"; else trap - HUP; fi
    pending_signal="$BUILD_TMP_SIGNAL_PENDING"
    BUILD_TMP_SIGNAL_PENDING=""
    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || true
    fi
    return "$rc"
}

build_tmp_intact() {
    local current_id owner
    [[ -n "$BUILD_TMP_ROOT" && -n "$BUILD_TMP_ROOT_ID" ]] || return 1
    [[ -d "$BUILD_TMP_ROOT" && ! -L "$BUILD_TMP_ROOT" ]] || return 1
    current_id=$(stat -c '%d:%i' "$BUILD_TMP_ROOT" 2>/dev/null) || return 1
    owner=$(stat -c '%u' "$BUILD_TMP_ROOT" 2>/dev/null) || return 1
    [[ "$current_id" == "$BUILD_TMP_ROOT_ID" && "$owner" == "$EUID" ]]
}

private_dir_intact() {
    local path="$1" expected_id="$2" current_id owner
    [[ -n "$path" && -n "$expected_id" ]] || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    current_id=$(stat -c '%d:%i' "$path" 2>/dev/null) || return 1
    owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
    [[ "$current_id" == "$expected_id" && "$owner" == "$EUID" ]]
}

file_identity() {
    local path="$1" owner identity
    [[ -f "$path" && ! -L "$path" ]] || return 1
    owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
    identity=$(stat -c '%d:%i' "$path" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" ]] || return 1
    printf '%s\n' "$identity"
}

cleanup_private_dir() {
    local path="$1" expected_id="$2" parent="$3" prefix="$4"
    [[ -n "$path" ]] || return 0
    case "$path" in
        "${parent%/}/${prefix}"*)
            if private_dir_intact "$path" "$expected_id"; then
                rm -rf -- "$path" 2>/dev/null || true
            fi
            ;;
    esac
}

cleanup_transaction_dirs() {
    if ((MANIFEST_INSTALLED == 0)); then
        cleanup_private_dir "$MANIFEST_TXN_ROOT" "$MANIFEST_TXN_ROOT_ID" \
            "$LIB_DIR" ".proxy-hub.manifest.txn."
        MANIFEST_TXN_ROOT=""
        MANIFEST_TXN_ROOT_ID=""
    fi
    if ((BUNDLE_INSTALLED == 0)); then
        cleanup_private_dir "$BUNDLE_TXN_ROOT" "$BUNDLE_TXN_ROOT_ID" \
            "$(dirname -- "$BUNDLE_FILE")" ".proxy-hub.bundle.txn."
        BUNDLE_TXN_ROOT=""
        BUNDLE_TXN_ROOT_ID=""
    fi
}

cleanup() {
    local path="${BUILD_TMP_ROOT:-}"
    if [[ -n "$path" ]]; then
        case "$path" in
            "${BUILD_TMP_PARENT%/}"/proxy-hub.build.*)
                if build_tmp_intact; then
                    rm -rf -- "$path" 2>/dev/null || true
                fi
                ;;
        esac
    fi
    BUILD_TMP_ROOT=""
    BUILD_TMP_ROOT_ID=""
    cleanup_transaction_dirs
    if ((RELEASE_LOCK_HELD == 1)); then
        if ((RELEASE_LOCK_SAFE_TO_RELEASE == 1)); then
            release_release_lock || true
        else
            echo "error: retaining identity-bound release lock for uncertain artifact state" >&2
        fi
    fi
}

cleanup_signal() {
    local signal="$1" fallback_status="$2"
    trap - EXIT INT TERM HUP
    cleanup
    kill -s "$signal" "$$" 2>/dev/null || exit "$fallback_status"
    exit "$fallback_status"
}

prepare_artifact_transaction() {
    local kind="$1" target="$2" source="$3" txn_root="$4" txn_root_id="$5" mode="$6"
    local new_path="$txn_root/new" old_path="$txn_root/old" new_id old_id target_device new_device

    private_dir_intact "$txn_root" "$txn_root_id" || return 1
    [[ ! -e "$target" || (-f "$target" && ! -L "$target") ]] || {
        echo "error: refusing unsafe artifact target: $target" >&2
        return 1
    }
    command cp -- "$source" "$new_path" || return 1
    chmod "$mode" "$new_path" || return 1
    new_id=$(file_identity "$new_path") || return 1
    target_device=$(stat -c '%d' "$(dirname -- "$target")" 2>/dev/null) || return 1
    new_device=$(stat -c '%d' "$new_path" 2>/dev/null) || return 1
    [[ "$new_device" == "$target_device" ]] || {
        echo "error: transaction staging is not on the target filesystem: $target" >&2
        return 1
    }

    old_id=""
    case "$kind" in
        manifest) MANIFEST_OLD_EXISTS=0 ;;
        bundle) BUNDLE_OLD_EXISTS=0 ;;
        *) return 1 ;;
    esac
    if [[ -e "$target" ]]; then
        file_identity "$target" >/dev/null || return 1
        command cp -p -- "$target" "$old_path" || return 1
        old_id=$(file_identity "$old_path") || return 1
        case "$kind" in
            manifest) MANIFEST_OLD_EXISTS=1 ;;
            bundle) BUNDLE_OLD_EXISTS=1 ;;
        esac
    fi

    case "$kind" in
        manifest)
            MANIFEST_NEW_ID="$new_id"
            MANIFEST_OLD_ID="$old_id"
            ;;
        bundle)
            BUNDLE_NEW_ID="$new_id"
            BUNDLE_OLD_ID="$old_id"
            ;;
    esac
}

publish_artifact() {
    local kind="$1" target txn_root txn_root_id new_id target_id="" rc=0
    case "$kind" in
        manifest)
            target="$MANIFEST_FILE"
            txn_root="$MANIFEST_TXN_ROOT"
            txn_root_id="$MANIFEST_TXN_ROOT_ID"
            new_id="$MANIFEST_NEW_ID"
            ;;
        bundle)
            target="$BUNDLE_FILE"
            txn_root="$BUNDLE_TXN_ROOT"
            txn_root_id="$BUNDLE_TXN_ROOT_ID"
            new_id="$BUNDLE_NEW_ID"
            ;;
        *) return 1 ;;
    esac

    private_dir_intact "$txn_root" "$txn_root_id" || return 1
    [[ "$(file_identity "$txn_root/new" 2>/dev/null || true)" == "$new_id" ]] || return 1
    if mv -f -- "$txn_root/new" "$target"; then
        rc=0
    else
        rc=$?
    fi
    target_id=$(file_identity "$target" 2>/dev/null || true)
    if [[ "$target_id" == "$new_id" ]]; then
        case "$kind" in
            manifest) MANIFEST_INSTALLED=1 ;;
            bundle) BUNDLE_INSTALLED=1 ;;
        esac
    else
        return 1
    fi
    return "$rc"
}

rollback_artifact() {
    local kind="$1" target txn_root txn_root_id new_id old_id old_exists installed
    local target_id="" restored_id="" rc=0
    case "$kind" in
        manifest)
            target="$MANIFEST_FILE"
            txn_root="$MANIFEST_TXN_ROOT"
            txn_root_id="$MANIFEST_TXN_ROOT_ID"
            new_id="$MANIFEST_NEW_ID"
            old_id="$MANIFEST_OLD_ID"
            old_exists="$MANIFEST_OLD_EXISTS"
            installed="$MANIFEST_INSTALLED"
            ;;
        bundle)
            target="$BUNDLE_FILE"
            txn_root="$BUNDLE_TXN_ROOT"
            txn_root_id="$BUNDLE_TXN_ROOT_ID"
            new_id="$BUNDLE_NEW_ID"
            old_id="$BUNDLE_OLD_ID"
            old_exists="$BUNDLE_OLD_EXISTS"
            installed="$BUNDLE_INSTALLED"
            ;;
        *) return 1 ;;
    esac
    ((installed == 1)) || return 0
    private_dir_intact "$txn_root" "$txn_root_id" || return 1
    target_id=$(file_identity "$target" 2>/dev/null || true)
    [[ "$target_id" == "$new_id" ]] || {
        echo "error: refusing rollback after artifact target identity changed: $target" >&2
        return 1
    }

    if ((old_exists == 1)); then
        [[ "$(file_identity "$txn_root/old" 2>/dev/null || true)" == "$old_id" ]] || return 1
        if mv -f -- "$txn_root/old" "$target"; then
            rc=0
        else
            rc=$?
        fi
        restored_id=$(file_identity "$target" 2>/dev/null || true)
        [[ "$restored_id" == "$old_id" ]] || return 1
        ((rc == 0)) || return "$rc"
    else
        rm -f -- "$target" || return 1
        [[ ! -e "$target" && ! -L "$target" ]] || return 1
    fi

    case "$kind" in
        manifest) MANIFEST_INSTALLED=0 ;;
        bundle) BUNDLE_INSTALLED=0 ;;
    esac
}

rollback_transaction() {
    local rc=0
    rollback_artifact bundle || rc=1
    rollback_artifact manifest || rc=1
    return "$rc"
}

discard_transaction_dirs() {
    local rc=0
    if [[ -n "$MANIFEST_TXN_ROOT" ]]; then
        if private_dir_intact "$MANIFEST_TXN_ROOT" "$MANIFEST_TXN_ROOT_ID"; then
            rm -rf -- "$MANIFEST_TXN_ROOT" || rc=1
        else
            rc=1
        fi
    fi
    if [[ -n "$BUNDLE_TXN_ROOT" ]]; then
        if private_dir_intact "$BUNDLE_TXN_ROOT" "$BUNDLE_TXN_ROOT_ID"; then
            rm -rf -- "$BUNDLE_TXN_ROOT" || rc=1
        else
            rc=1
        fi
    fi
    if ((rc == 0)); then
        MANIFEST_TXN_ROOT=""
        MANIFEST_TXN_ROOT_ID=""
        BUNDLE_TXN_ROOT=""
        BUNDLE_TXN_ROOT_ID=""
        MANIFEST_INSTALLED=0
        BUNDLE_INSTALLED=0
    fi
    return "$rc"
}

defer_transaction_signal() {
    [[ -n "$BUILD_TMP_SIGNAL_PENDING" ]] || BUILD_TMP_SIGNAL_PENDING="$1"
}

begin_transaction_signal_deferral() {
    BUILD_TMP_SIGNAL_PENDING=""
    TXN_SAVED_INT=$(trap -p INT || true)
    TXN_SAVED_TERM=$(trap -p TERM || true)
    TXN_SAVED_HUP=$(trap -p HUP || true)
    trap 'defer_transaction_signal INT' INT
    trap 'defer_transaction_signal TERM' TERM
    trap 'defer_transaction_signal HUP' HUP
}

end_transaction_signal_deferral() {
    local pending_signal="$BUILD_TMP_SIGNAL_PENDING"
    if [[ -n "$TXN_SAVED_INT" ]]; then eval "$TXN_SAVED_INT"; else trap - INT; fi
    if [[ -n "$TXN_SAVED_TERM" ]]; then eval "$TXN_SAVED_TERM"; else trap - TERM; fi
    if [[ -n "$TXN_SAVED_HUP" ]]; then eval "$TXN_SAVED_HUP"; else trap - HUP; fi
    BUILD_TMP_SIGNAL_PENDING=""
    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'cleanup_signal INT 130' INT
trap 'cleanup_signal TERM 143' TERM
trap 'cleanup_signal HUP 129' HUP
umask 077

acquire_release_lock
prepare_tmp_parent
publish_build_tmp || {
    echo "error: cannot create a private build directory" >&2
    exit 1
}

HEADER_FILE="$BUILD_TMP_ROOT/header"
BODY_FILE="$BUILD_TMP_ROOT/body"
CANONICAL_FILE="$BUILD_TMP_ROOT/manifest.canonical"
MANIFEST_TMP="$BUILD_TMP_ROOT/manifest.sha256"
BUNDLE_TMP="$BUILD_TMP_ROOT/proxy-hub.bundle.sh"

sed -n '1,16p' "$ROOT_DIR/proxy-hub.sh" > "$HEADER_FILE"
release_lock_intact || {
    echo "error: release lock identity changed before source snapshot" >&2
    exit 1
}
reject_nul "$HEADER_FILE" "bundle header"
: > "$BODY_FILE"
: > "$CANONICAL_FILE"

printf 'api=1\n' >> "$CANONICAL_FILE"
declare -a DIGESTS=()
for i in "${!MODULES[@]}"; do
    release_lock_intact || {
        echo "error: release lock identity changed during source snapshot" >&2
        exit 1
    }
    module="${MODULES[$i]}"
    module_path="$LIB_DIR/$module"
    [[ -f "$module_path" && ! -L "$module_path" ]] || {
        echo "error: missing or unsafe module: $module_path" >&2
        exit 1
    }
    reject_nul "$module_path" "module $module"
    bash -n "$module_path"
    digest=$(hash_file "$module_path")
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "error: invalid digest for $module" >&2
        exit 1
    }
    DIGESTS+=("$digest")
    printf '%s\0%s\n' "$module" "$digest" >> "$CANONICAL_FILE"
    command cat -- "$module_path" >> "$BODY_FILE"
    if ((i + 1 < ${#MODULES[@]})); then
        printf '\n' >> "$BODY_FILE"
    fi
done
reject_nul "$BODY_FILE" "assembled bundle body"

manifest_build_id=$(hash_file "$CANONICAL_FILE")
{
    printf '%s\n' '# proxy-hub-manifest-v1'
    printf '%s\n' '# api=1'
    printf '# build-id=%s\n' "$manifest_build_id"
    for i in "${!MODULES[@]}"; do
        printf '%s  %s\n' "${DIGESTS[$i]}" "${MODULES[$i]}"
    done
    printf '%s\n' '# proxy-hub-manifest-end-v1'
} > "$MANIFEST_TMP"

header_bytes=$(wc -c < "$HEADER_FILE" | tr -d '[:space:]')
header_sha=$(hash_file "$HEADER_FILE")
body_bytes=$(wc -c < "$BODY_FILE" | tr -d '[:space:]')
body_sha=$(hash_file "$BODY_FILE")

{
    command cat -- "$HEADER_FILE" "$BODY_FILE"
    printf '%s\n' '# proxy-hub-bundle-manifest-v1'
    printf '# header-bytes=%s header-sha256=%s\n' "$header_bytes" "$header_sha"
    printf '# body-bytes=%s body-sha256=%s\n' "$body_bytes" "$body_sha"
    printf '# build-id=%s\n' "$body_sha"
    printf '# module-count=%s\n' "${#MODULES[@]}"
    printf '%s\n' '# proxy-hub-bundle-end-v1'
} > "$BUNDLE_TMP"

reject_nul "$BUNDLE_TMP" "generated bundle"
bash -n "$BUNDLE_TMP"
mkdir -p "$ROOT_DIR/dist"
build_tmp_intact || {
    echo "error: build staging directory identity changed" >&2
    exit 1
}
release_lock_intact || {
    echo "error: release lock identity changed before artifact transaction" >&2
    exit 1
}
chmod 644 "$MANIFEST_TMP"
chmod 755 "$BUNDLE_TMP"

# Each artifact is staged and backed up on its own destination filesystem.  The
# two fixed public paths are then replaced as a rollback-capable transaction;
# HUP/INT/TERM are deferred until the pair is either fully installed or fully
# restored.
publish_transaction_dir "$LIB_DIR" ".proxy-hub.manifest.txn." \
    MANIFEST_TXN_ROOT MANIFEST_TXN_ROOT_ID || {
    echo "error: cannot create private manifest transaction staging" >&2
    exit 1
}
publish_transaction_dir "$(dirname -- "$BUNDLE_FILE")" ".proxy-hub.bundle.txn." \
    BUNDLE_TXN_ROOT BUNDLE_TXN_ROOT_ID || {
    echo "error: cannot create private bundle transaction staging" >&2
    exit 1
}
prepare_artifact_transaction manifest "$MANIFEST_FILE" "$MANIFEST_TMP" \
    "$MANIFEST_TXN_ROOT" "$MANIFEST_TXN_ROOT_ID" 644 || {
    echo "error: cannot prepare manifest transaction" >&2
    exit 1
}
prepare_artifact_transaction bundle "$BUNDLE_FILE" "$BUNDLE_TMP" \
    "$BUNDLE_TXN_ROOT" "$BUNDLE_TXN_ROOT_ID" 755 || {
    echo "error: cannot prepare bundle transaction" >&2
    exit 1
}
build_tmp_intact || {
    echo "error: build staging directory identity changed before artifact cutover" >&2
    exit 1
}

transaction_rc=0
transaction_error=""
begin_transaction_signal_deferral
if ! mark_release_lock_uncertain; then
    transaction_rc=1
    transaction_error="could not publish the uncertain-state release lock before artifact cutover"
fi
if ! release_lock_intact; then
    transaction_rc=1
    transaction_error="release lock identity changed before artifact cutover"
fi
if [[ -n "$BUILD_TMP_SIGNAL_PENDING" ]]; then
    transaction_rc=1
    transaction_error="signal arrived before artifact cutover"
fi
if ((transaction_rc == 0)); then
    if ! release_lock_intact; then
        transaction_rc=1
        transaction_error="release lock identity changed before manifest replacement"
    fi
fi
if ((transaction_rc == 0)); then
    if ! publish_artifact manifest; then
        transaction_rc=1
        transaction_error="manifest replacement failed"
    fi
fi
if [[ -n "$BUILD_TMP_SIGNAL_PENDING" ]]; then
    transaction_rc=1
    transaction_error="signal arrived after manifest replacement"
fi
if ((transaction_rc == 0)); then
    if ! release_lock_intact; then
        transaction_rc=1
        transaction_error="release lock identity changed before bundle replacement"
    fi
fi
if ((transaction_rc == 0)); then
    if ! publish_artifact bundle; then
        transaction_rc=1
        transaction_error="bundle replacement failed"
    fi
fi
if [[ -n "$BUILD_TMP_SIGNAL_PENDING" ]]; then
    transaction_rc=1
    transaction_error="signal arrived after bundle replacement"
fi

if ((transaction_rc != 0)); then
    if ! rollback_transaction; then
        echo "error: artifact transaction rollback could not safely restore both artifacts" >&2
        end_transaction_signal_deferral
        exit 1
    fi
    discard_transaction_dirs || {
        echo "error: restored artifacts but could not clean verified transaction staging" >&2
        end_transaction_signal_deferral
        exit 1
    }
    RELEASE_LOCK_SAFE_TO_RELEASE=1
    [[ -z "$transaction_error" ]] || echo "error: $transaction_error; restored previous artifacts" >&2
    end_transaction_signal_deferral
    exit 1
fi

# This is the commit point: both public paths contain the same completed build.
# A signal already observed above rolls back; after this point private backups
# can be discarded without exposing a mixed build.
discard_transaction_dirs || {
    echo "error: artifacts committed but verified transaction staging could not be cleaned" >&2
    end_transaction_signal_deferral
    exit 1
}
RELEASE_LOCK_SAFE_TO_RELEASE=1
release_release_lock || {
    echo "error: artifacts committed but the release lock could not be safely removed" >&2
    end_transaction_signal_deferral
    exit 1
}
end_transaction_signal_deferral

printf 'manifest_build_id=%s\n' "$manifest_build_id"
printf 'bundle_build_id=%s\n' "$body_sha"
printf 'bundle=%s\n' "$BUNDLE_FILE"

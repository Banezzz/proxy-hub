install_deps() {
    log_info "$(msg install_deps)"

    # 根据包管理器设置包名
    local required_packages
    case "$PKG_MANAGER" in
        apt)
            required_packages=(curl unzip tar openssl ca-certificates iproute2 qrencode jq cron util-linux)
            ;;
        dnf|yum)
            required_packages=(curl unzip tar openssl ca-certificates iproute qrencode jq cronie util-linux)
            ;;
        apk)
            # Alpine Linux 特殊包名
            # libqrencode-tools 提供 qrencode 命令
            required_packages=(curl unzip tar openssl ca-certificates iproute2 libqrencode-tools bash coreutils jq flock)
            ;;
        *)
            required_packages=(curl unzip tar openssl ca-certificates iproute qrencode jq util-linux)
            ;;
    esac

    local missing_packages=()

    # 检查哪些包未安装
    for pkg in "${required_packages[@]}"; do
        if ! $PKG_CHECK "$pkg" >/dev/null 2>&1; then
            missing_packages+=("$pkg")
        fi
    done

    # 如果所有包都已安装，跳过
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_info "All dependencies already installed, skipping..."
        return
    fi

    # 只安装缺失的包
    log_info "Installing: ${missing_packages[*]}"
    $PKG_UPDATE >/dev/null 2>&1 || true
    if ! $PKG_INSTALL "${missing_packages[@]}" >/dev/null 2>&1; then
        log_error "Failed to install dependencies"
        return 1
    fi
}

xray_list_process_ids() {
    local proc pid comm verify_comm
    for proc in /proc/[0-9]*; do
        [[ -d "$proc" && -r "$proc/comm" ]] || continue
        IFS= read -r comm < "$proc/comm" 2>/dev/null || continue
        [[ "$comm" == xray ]] || continue
        pid="${proc##*/}"
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        IFS= read -r verify_comm < "$proc/comm" 2>/dev/null || continue
        [[ "$verify_comm" == xray ]] && printf '%s\n' "$pid"
    done
}

xray_process_exists() {
    [[ -n "$(xray_list_process_ids)" ]]
}

xray_runtime_has_only_service_pid() {
    local expected_pid="$1" pid count=0
    [[ "$expected_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
        ((++count))
        [[ "$pid" == "$expected_pid" ]] || return 1
    done < <(xray_list_process_ids)
    ((count == 1))
}

xray_pid_uses_binary() {
    local pid="$1" binary="$2" expected_id actual_id
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/exe" ]] || return 1
    expected_id=$(stat -Lc '%d:%i' "$binary" 2>/dev/null) || return 1
    actual_id=$(stat -Lc '%d:%i' "/proc/$pid/exe" 2>/dev/null) || return 1
    [[ "$actual_id" == "$expected_id" ]]
}

_xray_binary_metadata_matches() {
    local path="$1" expected_mode="$2" owner mode
    [[ -f "$path" && ! -L "$path" && "$expected_mode" =~ ^[0-7]{3,4}$ ]] || return 1
    IFS=: read -r owner mode < <(stat -c '%u:%a' "$path" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    ((8#$mode == 8#$expected_mode))
}

_xray_binary_matches() {
    local path="$1" expected_digest="$2" expected_mode="$3" actual_digest
    _xray_binary_metadata_matches "$path" "$expected_mode" || return 1
    actual_digest=$(_xray_sha256_file "$path" 2>/dev/null) || return 1
    [[ "$actual_digest" == "$expected_digest" ]]
}

_xray_discard_state_payload() {
    local payload="$1" expected_id="$2" actual_id owner links
    [[ ! -e "$payload" && ! -L "$payload" ]] && return 0
    [[ -f "$payload" && ! -L "$payload" ]] || return 1
    actual_id=$(stat -Lc '%d:%i' "$payload" 2>/dev/null) || return 1
    IFS=: read -r owner links < <(stat -c '%u:%h' "$payload" 2>/dev/null) || return 1
    [[ "$actual_id" == "$expected_id" && "$owner" == "$EUID" && "$links" == 1 ]] || return 1
    unlink "$payload" || return 1
    _xray_sync_path "$(dirname "$payload")"
}

_xray_check_disk_space() {
    local directory="$1" required="$2" available_kb
    available_kb=$(df -Pk "$directory" 2>/dev/null | awk 'NR == 2 {print $4}') || return 1
    [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1
    ((available_kb * 1024 >= required + 1048576)) || {
        log_error "Not enough free space in $directory for the Xray update"
        return 1
    }
}

xray_preserve_transaction_target() {
    local target="$1" preserved="$2" expected_digest="$3" expected_mode="$4" actual_digest
    if ! _xray_binary_metadata_matches "$target" "$expected_mode"; then
        [[ ! -e "$target" && ! -L "$target" ]] || XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Refusing to move an unclassifiable Xray transaction target: $target"
        return 1
    fi
    if [[ -e "$preserved" || -L "$preserved" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Refusing to overwrite an existing Xray transaction stage: $preserved"
        return 1
    fi
    mv -n -T -- "$target" "$preserved" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "No-clobber Xray staging did not move the canonical target"
        return 1
    fi
    _xray_binary_metadata_matches "$preserved" "$expected_mode" || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    _xray_sync_path "$preserved" || return 1
    _xray_sync_path "$(dirname "$target")" || return 1
    actual_digest=$(_xray_sha256_file "$preserved" 2>/dev/null) || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Xray target changed at the transaction cutover; preserving it at $preserved"
        if [[ ! -e "$target" && ! -L "$target" ]]; then
            ln "$preserved" "$target" 2>/dev/null && _xray_sync_path "$(dirname "$target")" || true
        fi
        return 1
    fi
}

xray_copy_verified_backup() {
    local source="$1" copy_stage="$2" backup="$3" expected_digest="$4" mode="$5"
    local copy_id source_id backup_id
    _xray_binary_matches "$source" "$expected_digest" "$mode" || return 1
    [[ ! -e "$copy_stage" && ! -L "$copy_stage" && ! -e "$backup" && ! -L "$backup" ]] || return 1
    (umask 077; set -o noclobber; command cat -- "$source" > "$copy_stage") 2>/dev/null || return 1
    chmod "$mode" "$copy_stage" || return 1
    _xray_sync_path "$copy_stage" || return 1
    source_id=$(stat -Lc '%d:%i' "$source" 2>/dev/null) || return 1
    copy_id=$(stat -Lc '%d:%i' "$copy_stage" 2>/dev/null) || return 1
    [[ "$copy_id" != "$source_id" ]] || return 1
    _xray_binary_matches "$copy_stage" "$expected_digest" "$mode" || return 1
    ln "$copy_stage" "$backup" || return 1
    backup_id=$(stat -Lc '%d:%i' "$backup" 2>/dev/null) || return 1
    [[ "$backup_id" == "$copy_id" ]] || return 1
    _xray_sync_path "$backup" || return 1
    _xray_sync_path "$(dirname "$backup")"
}

xray_link_transaction_target() {
    local source="$1" target="$2" expected_digest="$3" expected_mode="$4"
    _xray_binary_matches "$source" "$expected_digest" "$expected_mode" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    fi
    ln "$source" "$target" || {
        [[ ! -e "$target" && ! -L "$target" ]] || XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    _xray_sync_path "$target" || return 1
    _xray_sync_path "$(dirname "$target")" || return 1
    _xray_binary_matches "$target" "$expected_digest" "$expected_mode" || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
}

xray_activate_transaction_binary() {
    local old_exists="$1" old_digest="$2" old_mode="$3" new_stage="$4" new_digest="$5" token="$6"
    local bin_dir displaced
    bin_dir=$(dirname "$XRAY_BIN")
    displaced="$bin_dir/.xray.displaced.$token"
    if [[ "$old_exists" == 1 ]]; then
        xray_preserve_transaction_target "$XRAY_BIN" "$displaced" "$old_digest" "$old_mode" || return 1
    elif [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "An Xray binary appeared during fresh-install validation; preserving it"
        return 1
    fi
    xray_link_transaction_target "$new_stage" "$XRAY_BIN" "$new_digest" 0755 || {
        log_error "Xray activation target appeared or changed; no existing target was overwritten"
        return 1
    }
}

xray_terminal_target_matches_state() {
    local phase="$1" old_exists="$2" old_digest="$3" old_mode="$4" new_digest="$5"
    local expected_digest="$new_digest" expected_mode=0755
    if [[ "$phase" == rolled-back && "$old_exists" == 0 ]]; then
        if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Fresh-install rollback journal conflicts with an existing Xray target"
            return 1
        fi
        return 0
    fi
    if [[ "$phase" == rolled-back ]]; then
        expected_digest="$old_digest"
        expected_mode="$old_mode"
    fi
    _xray_binary_matches "$XRAY_BIN" "$expected_digest" "$expected_mode" || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Terminal Xray journal does not match the current target content or metadata"
        return 1
    }
}

xray_terminal_runtime_matches_state() {
    local was_active="$1" pid
    if [[ "$was_active" == 1 ]]; then
        service_is_active xray && pid=$(service_main_pid xray 2>/dev/null) &&
            xray_pid_uses_binary "$pid" "$XRAY_BIN" &&
            xray_runtime_has_only_service_pid "$pid" || {
                XRAY_RECOVERY_EXTERNAL_CONFLICT=1
                log_error "Terminal Xray journal conflicts with the current service process set"
                return 1
            }
    elif [[ "$was_active" == 0 ]]; then
        if service_is_active xray || xray_process_exists; then
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Terminal inactive Xray journal conflicts with a running process"
            return 1
        fi
    else
        return 1
    fi
}

xray_finalize_transaction_evidence() {
    local phase="$1" old_exists="$2" old_digest="$3" old_mode="$4" new_digest="$5"
    local was_active="$6" bin_dir="$7" token="$8" restore_stage="$9" expected_state_id="${10}" state_id
    [[ "${XRAY_RECOVERY_EXTERNAL_CONFLICT:-0}" != 1 ]] || return 1
    state_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    [[ "$state_id" == "$expected_state_id" ]] || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    grep -Fxq "phase=$phase" "$XRAY_UPDATE_STATE_FILE" 2>/dev/null || return 1
    xray_terminal_target_matches_state "$phase" "$old_exists" "$old_digest" "$old_mode" "$new_digest" || return 1
    xray_terminal_runtime_matches_state "$was_active" || return 1
    _xray_cleanup_managed_stages "$bin_dir" "$token" "$restore_stage" || return 1
    xray_terminal_target_matches_state "$phase" "$old_exists" "$old_digest" "$old_mode" "$new_digest" || return 1
    xray_terminal_runtime_matches_state "$was_active" || return 1
    state_id=$(stat -Lc '%d:%i' "$XRAY_UPDATE_STATE_FILE" 2>/dev/null) || return 1
    [[ "$state_id" == "$expected_state_id" ]] || {
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        return 1
    }
    [[ "${XRAY_RECOVERY_EXTERNAL_CONFLICT:-0}" != 1 ]] || return 1
    unlink "$XRAY_UPDATE_STATE_FILE" || return 1
    _xray_sync_path "$(dirname "$XRAY_UPDATE_STATE_FILE")"
}

xray_adopt_loaded_transaction_state() {
    XRAY_TXN_TOKEN="$XRAY_STATE_TOKEN"
    XRAY_TXN_TARGET="$XRAY_STATE_TARGET"
    XRAY_TXN_NEW_DIGEST="$XRAY_STATE_NEW_DIGEST"
    XRAY_TXN_OLD_EXISTS="$XRAY_STATE_OLD_EXISTS"
    XRAY_TXN_OLD_DIGEST="$XRAY_STATE_OLD_DIGEST"
    XRAY_TXN_OLD_MODE="$XRAY_STATE_OLD_MODE"
    XRAY_TXN_BACKUP="$XRAY_STATE_BACKUP"
    XRAY_TXN_RESTORE_STAGE="$XRAY_STATE_RESTORE_STAGE"
    XRAY_TXN_WAS_ACTIVE="$XRAY_STATE_WAS_ACTIVE"
    XRAY_TXN_SCHEDULE_ENABLED="$XRAY_STATE_SCHEDULE_ENABLED"
    XRAY_TXN_SCHEDULE_LABEL="$XRAY_STATE_SCHEDULE_LABEL"
    XRAY_TXN_SCHEDULE_CRON="$XRAY_STATE_SCHEDULE_CRON"
    XRAY_TXN_SCHEDULE_CALENDAR="$XRAY_STATE_SCHEDULE_CALENDAR"
    XRAY_TXN_STATE_ID="$XRAY_STATE_FILE_ID"
    XRAY_TXN_PREPARED=1
}

xray_revalidate_release_request() {
    local intent="$1" target="$2" current="" decision
    case "$intent" in
        ordinary-install|channel-update|fixed-update) ;;
        *) return 1 ;;
    esac
    XRAY_TXN_VALIDATION_MODE=install
    XRAY_TXN_LOCKED_ACTION=install
    if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        [[ -f "$XRAY_BIN" && ! -L "$XRAY_BIN" ]] || {
            log_error "Existing Xray target is not a regular file"
            return 1
        }
        current=$(get_installed_xray_version "$XRAY_BIN" 2>/dev/null || true)
        if [[ -z "$current" ]]; then
            [[ "$intent" == fixed-update ]] || {
                log_error "Only a fixed version may repair an unidentifiable Xray binary"
                return 1
            }
            XRAY_TXN_VALIDATION_MODE=update
            XRAY_TXN_LOCKED_ACTION=repair
            return 0
        fi
        if [[ "$intent" == ordinary-install ]]; then
            log_info "Xray already installed: $current (leaving it unchanged)"
            return 10
        fi
        XRAY_TXN_VALIDATION_MODE=update
        if [[ "$intent" == channel-update ]]; then
            decision=$(xray_update_decision "$current" "$target" channel) || return 1
        else
            decision=$(xray_update_decision "$current" "$target" version) || return 1
        fi
        XRAY_TXN_LOCKED_ACTION="$decision"
        log_info "Current Xray: $current; target: $target"
        case "$decision" in
            noop) log_info "Xray is already at the selected channel target; no changes made"; return 10 ;;
            refuse) log_warn "Installed Xray $current is newer than channel target $target; refusing automatic downgrade"; return 10 ;;
            reinstall) log_warn "Explicit version request will reinstall $target" ;;
            downgrade) log_warn "Explicit version request will downgrade Xray to $target" ;;
        esac
    fi
}

xray_restore_transaction_binary() {
    local old_exists="$1" old_digest="$2" old_mode="$3" new_digest="$4" restore_stage="$5"
    local backup="$6" was_active="$7" token="$8" bin_dir current_digest="" source failed displaced
    bin_dir=$(dirname "$XRAY_BIN")
    failed="$bin_dir/.xray.failed.$token"
    displaced="$bin_dir/.xray.displaced.$token"
    [[ "${XRAY_RECOVERY_EXTERNAL_CONFLICT:-0}" != 1 ]] || return 1
    if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        if [[ ! -f "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Refusing recovery because the current Xray target is unclassifiable"
            return 1
        fi
        current_digest=$(_xray_sha256_file "$XRAY_BIN" 2>/dev/null) || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            return 1
        }
        if [[ "$old_exists" == 1 && "$current_digest" == "$old_digest" ]] &&
           _xray_binary_metadata_matches "$XRAY_BIN" "$old_mode"; then
            if [[ "$was_active" == 0 ]] && (service_is_active xray || xray_process_exists); then
                XRAY_RECOVERY_EXTERNAL_CONFLICT=1
                log_error "Refusing recovery because Xray became active outside the transaction"
                return 1
            fi
            return 0
        fi
        [[ "$current_digest" == "$new_digest" ]] &&
            _xray_binary_metadata_matches "$XRAY_BIN" 0755 || {
            XRAY_RECOVERY_EXTERNAL_CONFLICT=1
            log_error "Refusing recovery because the current Xray binary is external to the journal"
            return 1
        }
        if service_is_active xray || xray_process_exists; then
            _xray_stop_and_wait "$XRAY_BIN" "$new_digest" || return 1
        fi
        xray_preserve_transaction_target "$XRAY_BIN" "$failed" "$new_digest" 0755 || return 1
    elif service_is_active xray || xray_process_exists; then
        XRAY_RECOVERY_EXTERNAL_CONFLICT=1
        log_error "Refusing recovery while an unidentifiable Xray process exists"
        return 1
    fi
    [[ "$old_exists" == 1 ]] || return 0
    for source in "$restore_stage" "$displaced" "$backup"; do
        [[ -f "$source" && ! -L "$source" ]] || continue
        xray_link_transaction_target "$source" "$XRAY_BIN" "$old_digest" "$old_mode" && return 0
        [[ ! -e "$XRAY_BIN" && ! -L "$XRAY_BIN" ]] || return 1
    done
    log_error "No verified old Xray binary is available for recovery"
    return 1
}

install_xray() {
    local current
    recover_pending_xray_update_locked || return 1
    if current=$(get_installed_xray_version "$XRAY_BIN" 2>/dev/null); then
        # Creating a node must never silently replace or downgrade an existing
        # healthy Xray, even when a channel/version environment variable exists.
        ensure_xray_service_definition || return 1
        log_info "Xray already installed: $current (leaving it unchanged)"
        return 0
    fi
    if [[ -e "$XRAY_BIN" || -L "$XRAY_BIN" ]]; then
        log_error "An existing Xray binary cannot report a valid version; repair it with XRAY_VERSION=... xray-update"
        return 1
    fi
    log_info "$(msg install_xray)"
    install_xray_fresh || return 1
    ensure_xray_service_definition || return 1
    log_info "Xray installed successfully"
}

# Backward-compatible internal entry point.
install_xray_alpine() {
    install_xray_fresh && ensure_xray_service_definition
}

_xray_definition_should_publish() {
    local target="$1" legacy="$3" marker='# proxy-hub-managed: xray-service-v1' size
    [[ ! -e "$target" && ! -L "$target" ]] && return 0
    [[ -f "$target" && ! -L "$target" ]] || return 1
    grep -Fxq "$marker" "$target" 2>/dev/null && return 0
    size=$(stat -c '%s' "$target" 2>/dev/null) || return 1
    [[ "$size" =~ ^[0-9]+$ && "$size" -le "$(stat -c '%s' "$legacy")" ]] || return 1
    cmp -n "$size" "$target" "$legacy" >/dev/null 2>&1
}

_xray_publish_managed_definition() {
    local source="$1" target="$2" mode="$3"
    _xray_prepare_managed_file_parent "$target" || return 1
    chmod "$mode" "$source" || return 1
    _xray_sync_path "$source" || return 1
    mv -f -T -- "$source" "$target" || return 1
    _xray_sync_path "$target" || return 1
    _xray_sync_path "$(dirname "$target")"
}

# 创建 Xray OpenRC 服务脚本
create_xray_openrc_service() {
    local target=/etc/init.d/xray tmp legacy
    _xray_prepare_managed_file_parent "$target" || return 1
    mkdir -p /var/log/xray
    tmp=$(mktemp /etc/init.d/.xray.proxy-hub.XXXXXXXX) || return 1
    legacy="${tmp}.legacy"
    cat > "$tmp" <<'OPENRC_SERVICE'
#!/sbin/openrc-run
# proxy-hub-managed: xray-service-v1

name="xray"
description="Xray - A platform for building proxies"

command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0755 /var/log/xray
}
OPENRC_SERVICE
    grep -Fv '# proxy-hub-managed: xray-service-v1' "$tmp" > "$legacy" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    if ! _xray_definition_should_publish "$target" "$tmp" "$legacy"; then
        rm -f -- "$tmp" "$legacy"
        return 0
    fi
    bash -n "$tmp" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    rm -f -- "$legacy"
    _xray_publish_managed_definition "$tmp" "$target" 0755 || {
        rm -f -- "$tmp"
        return 1
    }
}

create_xray_systemd_service() {
    local unit_path=/etc/systemd/system/xray.service tmp legacy
    if [[ ! -e "$unit_path" && ! -L "$unit_path" ]] && systemctl cat xray.service >/dev/null 2>&1; then
        return 0
    fi
    _xray_prepare_managed_file_parent "$unit_path" || return 1
    mkdir -p /var/log/xray
    tmp=$(mktemp /etc/systemd/system/.xray.service.proxy-hub.XXXXXXXX) || return 1
    legacy="${tmp}.legacy"
    cat > "$tmp" <<'UNIT'
# proxy-hub-managed: xray-service-v1
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
    grep -Fv '# proxy-hub-managed: xray-service-v1' "$tmp" > "$legacy" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    if ! _xray_definition_should_publish "$unit_path" "$tmp" "$legacy"; then
        rm -f -- "$tmp" "$legacy"
        return 0
    fi
    grep -Fxq 'ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json' "$tmp" || {
        rm -f -- "$tmp" "$legacy"
        return 1
    }
    rm -f -- "$legacy"
    _xray_publish_managed_definition "$tmp" "$unit_path" 0644 || {
        rm -f -- "$tmp"
        return 1
    }
    systemctl daemon-reload
}

ensure_xray_service_definition() {
    if [[ "$INIT_SYSTEM" == openrc ]]; then
        create_xray_openrc_service
    else
        create_xray_systemd_service
    fi
}

# ============== sing-box 安装（AnyTLS / Hysteria2 支持） ==============

# 创建 sing-box systemd 服务
create_singbox_systemd_service() {
    cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service (AnyTLS / Hysteria2)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
}

# 创建 sing-box OpenRC 服务（Alpine）
create_singbox_openrc_service() {
    cat > /etc/init.d/sing-box <<'OPENRC_SERVICE'
#!/sbin/openrc-run

name="sing-box"
description="sing-box service (AnyTLS / Hysteria2)"

command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
OPENRC_SERVICE
    chmod 755 /etc/init.d/sing-box
}

# 安装 sing-box（下载官方预编译二进制，适用于所有发行版包括 Alpine）
# AnyTLS 协议需要 sing-box >= 1.12.0；同一内核也承载 Hysteria2。
install_singbox() {
    if [[ -f "$SINGBOX_BIN" ]] && "$SINGBOX_BIN" version &>/dev/null; then
        log_info "sing-box already installed, skipping..."
        return 0
    fi

    log_info "Installing sing-box (required for AnyTLS / Hysteria2)..."

    local arch sb_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   sb_arch="amd64" ;;
        aarch64|arm64)  sb_arch="arm64" ;;
        armv7l|armv7)   sb_arch="armv7" ;;
        i686|i386)      sb_arch="386" ;;
        *)
            log_error "Unsupported architecture for sing-box: $arch"
            return 1
            ;;
    esac

    # 获取最新版本号（安全的 API 解析）
    local tag version
    tag=$(fetch_github_release_tag "SagerNet/sing-box")
    if [[ -z "$tag" ]]; then
        log_error "Failed to get sing-box latest version"
        return 1
    fi
    version="${tag#v}"

    log_info "Installing sing-box ${tag} (${sb_arch})..."

    local download_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-linux-${sb_arch}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! secure_curl "$download_url" -o "${tmp_dir}/sing-box.tar.gz"; then
        log_error "Failed to download sing-box from $download_url"
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "$tmp_dir" 2>/dev/null; then
        log_error "Failed to extract sing-box archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    local extracted_bin
    extracted_bin=$(find "$tmp_dir" -type f -name sing-box 2>/dev/null | head -1)
    if [[ -z "$extracted_bin" ]]; then
        log_error "sing-box binary not found in archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$SINGBOX_DIR" /usr/local/bin
    install -m 755 "$extracted_bin" "$SINGBOX_BIN"
    rm -rf "$tmp_dir"

    # 创建服务（systemd 或 OpenRC）
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        create_singbox_openrc_service
    else
        create_singbox_systemd_service
    fi

    log_info "sing-box ${tag} installed successfully"
    return 0
}

# ============== GeoData 安装 ==============

# 按需确保 GeoIP/GeoSite 数据库存在（仅 WARP 分流的 geosite 规则需要）。
# 已存在则跳过，避免无谓的重复下载。
ensure_geodata() {
    if [[ -f "$XRAY_GEODATA_DIR/geoip.dat" ]] && [[ -f "$XRAY_GEODATA_DIR/geosite.dat" ]]; then
        return 0
    fi
    install_geodata
}

install_geodata() {
    log_info "$(msg install_geodata)"

    mkdir -p "$XRAY_GEODATA_DIR"

    local geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    local geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

    # 下载 geoip.dat（使用安全的 curl 选项，内联因为 execute_task 在子 shell 运行）
    if execute_task "curl --proto '=https' --tlsv1.2 -fsSL '$geoip_url' -o '$XRAY_GEODATA_DIR/geoip.dat'" "Downloading geoip.dat"; then
        # 创建软链接到 /usr/local/bin (Xray 查找位置)
        ln -sf "$XRAY_GEODATA_DIR/geoip.dat" /usr/local/bin/geoip.dat 2>/dev/null || true
    fi

    # 下载 geosite.dat
    if execute_task "curl --proto '=https' --tlsv1.2 -fsSL '$geosite_url' -o '$XRAY_GEODATA_DIR/geosite.dat'" "Downloading geosite.dat"; then
        ln -sf "$XRAY_GEODATA_DIR/geosite.dat" /usr/local/bin/geosite.dat 2>/dev/null || true
    fi

    # 设置自动更新定时任务（每周日 4:00）
    setup_geodata_cron

    log_info "$(msg geodata_updated)"
}

setup_geodata_cron() {
    # Use secure curl options in cron job (--proto, --tlsv1.2)
    local cron_cmd="curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o $XRAY_GEODATA_DIR/geoip.dat && curl --proto '=https' --tlsv1.2 -fsSL https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o $XRAY_GEODATA_DIR/geosite.dat"
    local cron_job="0 4 * * 0 $cron_cmd >/dev/null 2>&1"

    # 检查 crontab 命令是否存在
    if ! command -v crontab &>/dev/null; then
        return 0
    fi

    # 添加定时任务（先删除旧的）
    (crontab -l 2>/dev/null | grep -v 'geoip.dat' | grep -v 'geosite.dat'; echo "$cron_job") | crontab - 2>/dev/null || true
}

# ============== Xray 定时重启 ==============

XRAY_RESTART_CONF="/etc/proxy-hub/xray-restart.conf"
XRAY_RESTART_NAME="xray-restart"
XRAY_RESTART_SYSTEMD_SERVICE="/etc/systemd/system/${XRAY_RESTART_NAME}.service"
XRAY_RESTART_SYSTEMD_TIMER="/etc/systemd/system/${XRAY_RESTART_NAME}.timer"
XRAY_RESTART_CRON_MARKER="# proxy-hub-xray-restart"
XRAY_RESTART_HELPER="/usr/local/libexec/proxy-hub-xray-restart"

# 调度选择的全局返回值
XRAY_RESTART_LABEL=""
XRAY_RESTART_CRON=""
XRAY_RESTART_CALENDAR=""

is_xray_restart_enabled() {
    [[ -f "$XRAY_RESTART_CONF" ]] && grep -q "^RESTART_ENABLED=yes" "$XRAY_RESTART_CONF" 2>/dev/null
}

get_xray_restart_label() {
    [[ -f "$XRAY_RESTART_CONF" ]] || return 0
    grep "^RESTART_LABEL=" "$XRAY_RESTART_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"'
}

get_xray_restart_backend() {
    [[ -f "$XRAY_RESTART_CONF" ]] || return 0
    grep "^RESTART_BACKEND=" "$XRAY_RESTART_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"'
}

# 将标签翻译为人类可读字符串
xray_restart_describe_label() {
    case "$1" in
        daily)  msg xray_restart_daily ;;
        12h)    msg xray_restart_12h ;;
        6h)     msg xray_restart_6h ;;
        weekly) msg xray_restart_weekly ;;
        custom) msg xray_restart_custom ;;
        *)      echo "$1" ;;
    esac
}

save_xray_restart_config() {
    local label="$1" cron_expr="$2" systemd_cal="$3" backend="$4"
    mkdir -p "$(dirname "$XRAY_RESTART_CONF")"
    cat > "$XRAY_RESTART_CONF" <<EOF
# Xray periodic restart config - managed by proxy-hub
RESTART_ENABLED=yes
RESTART_LABEL="$label"
RESTART_CRON="$cron_expr"
RESTART_SYSTEMD_CALENDAR="$systemd_cal"
RESTART_BACKEND="$backend"
EOF
    chmod 600 "$XRAY_RESTART_CONF"
}

install_xray_restart_helper() {
    local target="$XRAY_RESTART_HELPER" tmp marker='# proxy-hub-managed: xray-restart-helper-v1'
    [[ "$target" == /usr/local/libexec/proxy-hub-xray-restart ]] || return 1
    _xray_prepare_managed_file_parent "$target" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] || return 1
        grep -Fxq "$marker" "$target" 2>/dev/null || {
            log_error "Refusing to overwrite an unmanaged restart helper: $target"
            return 1
        }
    fi
    tmp=$(mktemp /usr/local/libexec/.proxy-hub-xray-restart.XXXXXXXX) || return 1
    cat > "$tmp" <<'RESTART_HELPER'
#!/usr/bin/env bash
# proxy-hub-managed: xray-restart-helper-v1
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
lock=/run/proxy-hub-xray-lifecycle.lock

[[ "${EUID:-$(id -u)}" == 0 ]] || exit 1
[[ -d /run && ! -L /run && "$(stat -c '%u' /run 2>/dev/null)" == 0 ]] || exit 1
run_mode=$(stat -c '%a' /run 2>/dev/null) || exit 1
[[ "$run_mode" =~ ^[0-7]{3,4}$ ]] || exit 1
(((8#$run_mode & 022) == 0)) || exit 1
if [[ -e "$lock" || -L "$lock" ]]; then
    [[ -f "$lock" && ! -L "$lock" && "$(stat -c '%u' "$lock" 2>/dev/null)" == 0 ]] || exit 1
    lock_mode=$(stat -c '%a' "$lock" 2>/dev/null) || exit 1
    [[ "$lock_mode" =~ ^[0-7]{3,4}$ ]] || exit 1
    (((8#$lock_mode & 022) == 0)) || exit 1
fi
umask 077
exec 9>>"$lock" || exit 1
[[ -f "$lock" && ! -L "$lock" && "$(stat -c '%u' "$lock" 2>/dev/null)" == 0 ]] || exit 1
path_id=$(stat -Lc '%d:%i' "$lock" 2>/dev/null) || exit 1
fd_id=$(stat -Lc '%d:%i' "/proc/$$/fd/9" 2>/dev/null) || exit 1
[[ "$path_id" == "$fd_id" ]] || exit 1
flock -n 9 || exit 0

status=0
if command -v systemctl >/dev/null 2>&1; then
    for unit in xray sing-box; do
        systemctl is-active --quiet "$unit.service" 2>/dev/null || continue
        systemctl restart "$unit.service" >/dev/null 2>&1 || status=1
    done
elif command -v rc-service >/dev/null 2>&1; then
    for service in xray sing-box; do
        [[ -e "/etc/init.d/$service" ]] || continue
        rc-service "$service" status >/dev/null 2>&1 || continue
        rc-service "$service" restart >/dev/null 2>&1 || status=1
    done
fi
exit "$status"
RESTART_HELPER
    bash -n "$tmp" || {
        rm -f -- "$tmp"
        return 1
    }
    _xray_publish_managed_definition "$tmp" "$target" 0755 || {
        rm -f -- "$tmp"
        return 1
    }
}

# 通过 systemd timer + service 安装（Ubuntu/Debian/CentOS 等）
install_xray_restart_systemd() {
    local systemd_cal="$1"
    [[ "$XRAY_LIFECYCLE_LOCK" == "$XRAY_PRODUCTION_LIFECYCLE_LOCK" ]] || return 1
    install_xray_restart_helper || return 1

    cat > "$XRAY_RESTART_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Restart proxy cores (proxy-hub)
After=xray.service sing-box.service

[Service]
Type=oneshot
ExecStart=$XRAY_RESTART_HELPER
EOF

    cat > "$XRAY_RESTART_SYSTEMD_TIMER" <<EOF
[Unit]
Description=Periodic restart for Xray (proxy-hub)

[Timer]
OnCalendar=$systemd_cal
Persistent=true
Unit=${XRAY_RESTART_NAME}.service

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$XRAY_RESTART_SYSTEMD_SERVICE" "$XRAY_RESTART_SYSTEMD_TIMER"

    systemctl daemon-reload 2>/dev/null || return 1
    systemctl enable --now "${XRAY_RESTART_NAME}.timer" >/dev/null 2>&1 || return 1
    return 0
}

# 通过 crontab 安装（Alpine/OpenRC，以及自定义 cron 表达式场景）
install_xray_restart_cron() {
    local cron_expr="$1"
    [[ "$XRAY_LIFECYCLE_LOCK" == "$XRAY_PRODUCTION_LIFECYCLE_LOCK" ]] || return 1

    if ! command -v crontab &>/dev/null; then
        log_warn "crontab not available; cannot schedule Xray restart"
        return 1
    fi

    install_xray_restart_helper || return 1
    local cron_line="$cron_expr $XRAY_RESTART_HELPER >/dev/null 2>&1 $XRAY_RESTART_CRON_MARKER"

    if ! (crontab -l 2>/dev/null | grep -v "$XRAY_RESTART_CRON_MARKER"; echo "$cron_line") | crontab - 2>/dev/null; then
        log_warn "Failed to write crontab for Xray restart"
        return 1
    fi

    # Alpine / OpenRC：确保 crond 已启用并运行
    if [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service &>/dev/null; then
        rc-service crond status &>/dev/null || rc-service crond start &>/dev/null || true
        rc-update show default 2>/dev/null | grep -q crond || rc-update add crond default &>/dev/null || true
    fi

    return 0
}

remove_xray_restart_systemd() {
    if command -v systemctl &>/dev/null && [[ -f "$XRAY_RESTART_SYSTEMD_TIMER" ]]; then
        systemctl disable --now "${XRAY_RESTART_NAME}.timer" >/dev/null 2>&1 || true
    fi
    rm -f "$XRAY_RESTART_SYSTEMD_SERVICE" "$XRAY_RESTART_SYSTEMD_TIMER"
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

remove_xray_restart_cron() {
    if command -v crontab &>/dev/null; then
        crontab -l 2>/dev/null | grep -v "$XRAY_RESTART_CRON_MARKER" | crontab - 2>/dev/null || true
    fi
}

remove_xray_restart_schedule() {
    remove_xray_restart_systemd
    remove_xray_restart_cron
    rm -f "$XRAY_RESTART_CONF"
}

# 统一安装入口
# $1 label  $2 cron expr  $3 systemd OnCalendar (可为空)
setup_xray_restart_schedule() {
    local label="$1" cron_expr="$2" systemd_cal="$3"

    # Publish the validated fixed-path lock helper before disturbing an existing
    # schedule, so helper creation failure leaves the current schedule intact.
    install_xray_restart_helper || return 1

    # 清理旧的
    remove_xray_restart_systemd
    remove_xray_restart_cron

    local backend=""
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl &>/dev/null && [[ -n "$systemd_cal" ]]; then
        if install_xray_restart_systemd "$systemd_cal"; then
            backend="systemd-timer"
        else
            log_warn "systemd timer setup failed, falling back to cron"
            if install_xray_restart_cron "$cron_expr"; then
                backend="cron"
            fi
        fi
    else
        if install_xray_restart_cron "$cron_expr"; then
            backend="cron"
        fi
    fi

    if [[ -z "$backend" ]]; then
        return 1
    fi

    save_xray_restart_config "$label" "$cron_expr" "$systemd_cal" "$backend"
    return 0
}

# 让用户选择一个预设调度或输入 cron 表达式
# 结果写入 XRAY_RESTART_LABEL / XRAY_RESTART_CRON / XRAY_RESTART_CALENDAR
prompt_xray_restart_choose_schedule() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  $(msg xray_restart_choose)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} $(msg xray_restart_daily) [${YELLOW}$(msg xray_restart_default)${NC}]"
    echo -e "  ${GREEN}2.${NC} $(msg xray_restart_12h)"
    echo -e "  ${GREEN}3.${NC} $(msg xray_restart_6h)"
    echo -e "  ${GREEN}4.${NC} $(msg xray_restart_weekly)"
    echo -e "  ${GREEN}5.${NC} $(msg xray_restart_custom)"
    echo ""
    echo -n "  $(msg menu_choice) [1-5]: "
    read -r choice
    case "$choice" in
        2)
            XRAY_RESTART_LABEL="12h"
            XRAY_RESTART_CRON="0 */12 * * *"
            XRAY_RESTART_CALENDAR="*-*-* 00/12:00:00"
            ;;
        3)
            XRAY_RESTART_LABEL="6h"
            XRAY_RESTART_CRON="0 */6 * * *"
            XRAY_RESTART_CALENDAR="*-*-* 00/6:00:00"
            ;;
        4)
            XRAY_RESTART_LABEL="weekly"
            XRAY_RESTART_CRON="0 4 * * 0"
            XRAY_RESTART_CALENDAR="Sun *-*-* 04:00:00"
            ;;
        5)
            echo ""
            echo -e "  $(msg xray_restart_cron_hint)"
            echo -n "  $(msg xray_restart_cron_prompt): "
            local custom_cron
            read -r custom_cron
            # 简单验证：5 个字段
            if [[ -z "$custom_cron" || ! "$custom_cron" =~ ^[0-9*/?,[:space:]-]+$ ]] \
                || [[ $(awk '{print NF}' <<< "$custom_cron") -ne 5 ]]; then
                log_warn "$(msg xray_restart_cron_invalid)"
                XRAY_RESTART_LABEL="daily"
                XRAY_RESTART_CRON="0 4 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 04:00:00"
            else
                XRAY_RESTART_LABEL="custom"
                XRAY_RESTART_CRON="$custom_cron"
                # 自定义 cron 强制走 crontab 后端
                XRAY_RESTART_CALENDAR=""
            fi
            ;;
        *)
            XRAY_RESTART_LABEL="daily"
            XRAY_RESTART_CRON="0 4 * * *"
            XRAY_RESTART_CALENDAR="*-*-* 04:00:00"
            ;;
    esac
}

# 创建节点时询问是否启用定时重启
prompt_xray_restart_on_install() {
    # 已配置过则仅提示当前状态
    if is_xray_restart_enabled; then
        local cur
        cur=$(xray_restart_describe_label "$(get_xray_restart_label)")
        log_info "$(msg xray_restart_already): $cur"
        return 0
    fi

    # 支持环境变量自动选择
    if [[ -n "${restart:-}" ]]; then
        case "$restart" in
            no|false|0|n)
                return 0
                ;;
            daily|yes|true|1|y)
                XRAY_RESTART_LABEL="daily"
                XRAY_RESTART_CRON="0 4 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 04:00:00"
                ;;
            12h)
                XRAY_RESTART_LABEL="12h"
                XRAY_RESTART_CRON="0 */12 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 00/12:00:00"
                ;;
            6h)
                XRAY_RESTART_LABEL="6h"
                XRAY_RESTART_CRON="0 */6 * * *"
                XRAY_RESTART_CALENDAR="*-*-* 00/6:00:00"
                ;;
            weekly)
                XRAY_RESTART_LABEL="weekly"
                XRAY_RESTART_CRON="0 4 * * 0"
                XRAY_RESTART_CALENDAR="Sun *-*-* 04:00:00"
                ;;
            *)
                log_warn "Unknown restart value: $restart (use: daily/12h/6h/weekly/no)"
                return 0
                ;;
        esac
        if setup_xray_restart_schedule "$XRAY_RESTART_LABEL" "$XRAY_RESTART_CRON" "$XRAY_RESTART_CALENDAR"; then
            log_info "$(msg xray_restart_enabled): $(xray_restart_describe_label "$XRAY_RESTART_LABEL")"
        else
            log_warn "$(msg xray_restart_setup_failed)"
        fi
        return 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}⏰${NC}  $(msg xray_restart_prompt)"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -n "  [y/N]: "
    local answer
    read -r answer
    [[ ! "$answer" =~ ^[Yy]$ ]] && return 0

    prompt_xray_restart_choose_schedule

    if setup_xray_restart_schedule "$XRAY_RESTART_LABEL" "$XRAY_RESTART_CRON" "$XRAY_RESTART_CALENDAR"; then
        log_info "$(msg xray_restart_enabled): $(xray_restart_describe_label "$XRAY_RESTART_LABEL")"
    else
        log_warn "$(msg xray_restart_setup_failed)"
    fi
}

# 工具菜单入口：显示当前状态并允许修改/禁用
cmd_xray_restart() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                  $(msg xray_restart_title)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        if is_xray_restart_enabled; then
            local cur backend
            cur=$(xray_restart_describe_label "$(get_xray_restart_label)")
            backend=$(get_xray_restart_backend)
            echo -e "  $(msg xray_restart_status): ${GREEN}$(msg xray_restart_status_on)${NC}"
            echo -e "  $(msg xray_restart_current): ${YELLOW}$cur${NC}"
            echo -e "  $(msg xray_restart_backend): ${BLUE}$backend${NC}"
        else
            echo -e "  $(msg xray_restart_status): ${RED}$(msg xray_restart_status_off)${NC}"
        fi
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1.${NC} $(msg xray_restart_action_set)"
        echo -e "  ${GREEN}2.${NC} $(msg xray_restart_action_disable)"
        echo -e "  ${RED}0.${NC} $(msg xray_restart_back)"
        echo ""
        echo -n "  $(msg menu_choice) [0-2]: "
        local choice
        read -r choice
        case "$choice" in
            1)
                prompt_xray_restart_choose_schedule
                if setup_xray_restart_schedule "$XRAY_RESTART_LABEL" "$XRAY_RESTART_CRON" "$XRAY_RESTART_CALENDAR"; then
                    log_info "$(msg xray_restart_enabled): $(xray_restart_describe_label "$XRAY_RESTART_LABEL")"
                else
                    log_warn "$(msg xray_restart_setup_failed)"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                if is_xray_restart_enabled; then
                    remove_xray_restart_schedule
                    log_info "$(msg xray_restart_disabled)"
                else
                    log_info "$(msg xray_restart_not_enabled)"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============== 协议类型选择 ==============

# 协议类型: vision, xhttp, both, shadowsocks, anytls, anytls_reality, hysteria2
#
# 节点作用域变量（PROTOCOL_TYPE / UUID / SNI / REALITY 密钥 / 各协议密码等）的默认值
# 统一在 lib/00_security_state.sh 的 reset_node_state() 中定义，并在该模块加载时执行一次。
# 此处曾经维护一份平行的默认值清单，但它只覆盖了部分字段（缺少 UUID / SNI / REALITY 密钥），
# 导致 anytls_reality 这类不赋值 UUID 的协议分支在 `set -u` 下于 save_env 处崩溃。
# 因此不要在这里重新引入清单——新增字段请只改 reset_node_state()。

# Shadowsocks 支持的加密方式
SS_METHODS_2022=(
    "2022-blake3-aes-256-gcm"
    "2022-blake3-chacha20-poly1305"
)
SS_METHODS_LEGACY=(
    "chacha20-ietf-poly1305"
    "aes-256-gcm"
)

# ============== 端口管理 ==============

# 验证端口号
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        echo -e "${RED}[ERROR]${NC} 端口必须是 1-65535 之间的数字！"
        return 1
    fi
    return 0
}

# 检查端口运行状态
check_port_status() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# 开放端口 (跨系统支持)
open_firewall_port() {
    local port="$1"

    # iptables (if available)
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true

        # IPv6
        if [[ -f /proc/net/if_inet6 ]] && command -v ip6tables &>/dev/null; then
            ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi

        # 持久化 (如果有 netfilter-persistent)
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null || true
        fi
    fi

    # firewalld (if available)
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-port="${port}/udp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi

    # ufw (if available)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port" 2>/dev/null || true
    fi
}

# 获取当前端口配置
get_current_ports() {
    local ssh_config="/etc/ssh/sshd_config"

    # SSH 端口
    CURRENT_SSH=$(grep "^Port" "$ssh_config" 2>/dev/null | head -n 1 | awk '{print $2}')
    [[ -z "$CURRENT_SSH" ]] && CURRENT_SSH=22

    # Xray 端口
    if [[ -f "$XRAY_CONF" ]] && command -v jq &>/dev/null; then
        CURRENT_VISION=$(jq -r '.inbounds[] | select(.tag=="vision_node" or .tag=="vless-reality-vision" or .settings.clients) | .port' "$XRAY_CONF" 2>/dev/null | head -1)
        CURRENT_XHTTP=$(jq -r '.inbounds[] | select(.tag=="xhttp_node") | .port' "$XRAY_CONF" 2>/dev/null | head -1)
    else
        CURRENT_VISION="N/A"
        CURRENT_XHTTP="N/A"
    fi

    [[ -z "$CURRENT_VISION" || "$CURRENT_VISION" == "null" ]] && CURRENT_VISION="N/A"
    [[ -z "$CURRENT_XHTTP" || "$CURRENT_XHTTP" == "null" ]] && CURRENT_XHTTP="N/A"
}

SSH_ROLLBACK_PID=""
SSH_ROLLBACK_ID=""
SSH_ROLLBACK_CONFIG=""
SSH_ROLLBACK_BACKUP=""
SSH_ROLLBACK_BACKUP_ID=""
SSH_ROLLBACK_ORIGINAL_PORT=""
SSH_ROLLBACK_MARKER=""
SSH_ROLLBACK_MARKER_TOKEN=""
SSH_ROLLBACK_RESULT_FILE=""
SSH_ROLLBACK_STATE_DIR=""
SSH_ROLLBACK_STATE_ID=""
SSH_ROLLBACK_STATE_TOKEN=""
SSH_ROLLBACK_TOKEN_FILE=""
SSH_ROLLBACK_TOKEN_ID=""
SSH_ROLLBACK_SIGNAL_PENDING=""
SSH_ROLLBACK_CLAIM_RESULT=""

ssh_rollback_sync_path() {
    local path="$1"
    command -v sync >/dev/null 2>&1 || return 1
    if sync --help 2>&1 | grep -q -- '--file-system'; then
        command sync -f "$path"
    else
        command sync
    fi
}

ssh_rollback_file_identity() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    stat -c '%d:%i' "$path" 2>/dev/null
}

ssh_rollback_tracked_file() {
    local path="$1" expected_id="$2" owner identity
    [[ -n "$path" && -n "$expected_id" && -f "$path" && ! -L "$path" ]] || return 1
    owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
    identity=$(ssh_rollback_file_identity "$path") || return 1
    [[ "$owner" == "$EUID" && "$identity" == "$expected_id" ]]
}

ssh_rollback_owned_file() {
    local path="$1" expected_id="$2" mode
    ssh_rollback_tracked_file "$path" "$expected_id" || return 1
    mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 077) == 0 ))
}

ssh_rollback_backup_is_valid() {
    local backup_file="$1"
    if [[ -n "$SSH_ROLLBACK_STATE_DIR" ]]; then
        ssh_rollback_state_valid || return 1
        [[ "$backup_file" == "$SSH_ROLLBACK_STATE_DIR/sshd_config.backup" ]] || return 1
        ssh_rollback_owned_file "$backup_file" "$SSH_ROLLBACK_BACKUP_ID"
    else
        # Compatibility for the existing timer helper contract. Production
        # change_ssh_port always uses the stricter private-state branch above.
        ssh_rollback_tracked_file "$backup_file" "$SSH_ROLLBACK_BACKUP_ID"
    fi
}

ssh_rollback_state_valid() {
    local owner mode identity token_value
    [[ -n "$SSH_ROLLBACK_STATE_DIR" && -n "$SSH_ROLLBACK_STATE_ID" \
        && -n "$SSH_ROLLBACK_STATE_TOKEN" && -n "$SSH_ROLLBACK_TOKEN_FILE" \
        && -n "$SSH_ROLLBACK_TOKEN_ID" ]] || return 1
    [[ -d "$SSH_ROLLBACK_STATE_DIR" && ! -L "$SSH_ROLLBACK_STATE_DIR" ]] || return 1
    owner=$(stat -c '%u' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null) || return 1
    identity=$(stat -c '%d:%i' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]+$ \
        && "$identity" == "$SSH_ROLLBACK_STATE_ID" ]] || return 1
    (( (8#$mode & 077) == 0 )) || return 1
    [[ "$SSH_ROLLBACK_TOKEN_FILE" == "$SSH_ROLLBACK_STATE_DIR/token" ]] || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_TOKEN_FILE" "$SSH_ROLLBACK_TOKEN_ID" || return 1
    IFS= read -r token_value < "$SSH_ROLLBACK_TOKEN_FILE" || return 1
    [[ "$token_value" == "$SSH_ROLLBACK_STATE_TOKEN" ]] || return 1
    ssh_rollback_phase_current >/dev/null
}

ssh_rollback_phase_is_valid() {
    local phase="$1" phase_file phase_id phase_value
    [[ "$phase" == "pending" || "$phase" == "confirmed" || "$phase" == "rolling-back" ]] || return 1
    phase_file="$SSH_ROLLBACK_STATE_DIR/phase.$phase"
    [[ -f "$phase_file" && ! -L "$phase_file" ]] || return 1
    phase_id=$(ssh_rollback_file_identity "$phase_file") || return 1
    ssh_rollback_owned_file "$phase_file" "$phase_id" || return 1
    IFS= read -r phase_value < "$phase_file" || return 1
    [[ "$phase_value" == "$SSH_ROLLBACK_STATE_TOKEN" ]]
}

ssh_rollback_phase_current() {
    local phase found=""
    for phase in pending confirmed rolling-back; do
        if [[ -e "$SSH_ROLLBACK_STATE_DIR/phase.$phase" || -L "$SSH_ROLLBACK_STATE_DIR/phase.$phase" ]]; then
            [[ -z "$found" ]] || return 1
            ssh_rollback_phase_is_valid "$phase" || return 1
            found="$phase"
        fi
    done
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

ssh_rollback_claim_phase() {
    local target="$1" current source_file target_file
    SSH_ROLLBACK_CLAIM_RESULT=""
    [[ "$target" == "confirmed" || "$target" == "rolling-back" ]] || return 1
    ssh_rollback_state_valid || return 1
    current=$(ssh_rollback_phase_current) || return 1
    [[ "$current" == "pending" ]] || return 1
    source_file="$SSH_ROLLBACK_STATE_DIR/phase.pending"
    target_file="$SSH_ROLLBACK_STATE_DIR/phase.$target"
    [[ ! -e "$target_file" && ! -L "$target_file" ]] || return 1
    mv -- "$source_file" "$target_file" || return 1
    SSH_ROLLBACK_CLAIM_RESULT="$target"
    ssh_rollback_phase_is_valid "$target" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR" || return 2
}

ssh_rollback_prepare_state() {
    local state_record state_dir state_id state_token token_file token_id
    local saved_int saved_term saved_hup pending_signal

    [[ -z "$SSH_ROLLBACK_STATE_DIR" && -z "$SSH_ROLLBACK_STATE_ID" \
        && -z "$SSH_ROLLBACK_STATE_TOKEN" && -z "$SSH_ROLLBACK_TOKEN_FILE" \
        && -z "$SSH_ROLLBACK_TOKEN_ID" ]] || return 1
    declare -F lock_prepare_parent >/dev/null 2>&1 || return 1
    lock_prepare_parent || return 1

    SSH_ROLLBACK_SIGNAL_PENDING=""
    saved_int=$(trap -p INT || true)
    saved_term=$(trap -p TERM || true)
    saved_hup=$(trap -p HUP || true)
    trap 'SSH_ROLLBACK_SIGNAL_PENDING=INT' INT
    trap 'SSH_ROLLBACK_SIGNAL_PENDING=TERM' TERM
    trap 'SSH_ROLLBACK_SIGNAL_PENDING=HUP' HUP

    state_record=$(
        local candidate_dir="" candidate_id="" candidate_token candidate_token_id="" token_tmp phase_tmp complete=0
        trap '' INT TERM HUP
        umask 077
        cleanup_candidate_state() {
            ((complete == 0)) || return 0
            [[ -n "$candidate_dir" && -n "$candidate_id" \
                && -d "$candidate_dir" && ! -L "$candidate_dir" \
                && "$(stat -c '%d:%i' "$candidate_dir" 2>/dev/null)" == "$candidate_id" ]] || return 0
            [[ -n "$token_tmp" && -f "$token_tmp" && ! -L "$token_tmp" ]] && rm -f -- "$token_tmp"
            [[ -n "$phase_tmp" && -f "$phase_tmp" && ! -L "$phase_tmp" ]] && rm -f -- "$phase_tmp"
            [[ -f "$candidate_dir/phase.pending" && ! -L "$candidate_dir/phase.pending" ]] && rm -f -- "$candidate_dir/phase.pending"
            [[ -f "$candidate_dir/token" && ! -L "$candidate_dir/token" ]] && rm -f -- "$candidate_dir/token"
            rmdir "$candidate_dir" 2>/dev/null || true
        }
        trap cleanup_candidate_state EXIT
        candidate_token="${EUID}-$$-${RANDOM}-${RANDOM}"
        candidate_dir=$(mktemp -d "$LOCK_PARENT/ssh-rollback.XXXXXXXX") || exit 1
        candidate_id=$(stat -c '%d:%i' "$candidate_dir" 2>/dev/null) || {
            rmdir "$candidate_dir" 2>/dev/null || true
            exit 1
        }
        token_tmp="$candidate_dir/.token-${candidate_token}"
        if ! (set -o noclobber; printf '%s\n' "$candidate_token" > "$token_tmp") 2>/dev/null; then
            rmdir "$candidate_dir" 2>/dev/null || true
            exit 1
        fi
        chmod 600 "$token_tmp" 2>/dev/null || exit 1
        mv -- "$token_tmp" "$candidate_dir/token" || exit 1
        candidate_token_id=$(ssh_rollback_file_identity "$candidate_dir/token") || exit 1
        phase_tmp="$candidate_dir/.phase-${candidate_token}"
        if ! (set -o noclobber; printf '%s\n' "$candidate_token" > "$phase_tmp") 2>/dev/null; then
            exit 1
        fi
        chmod 600 "$phase_tmp" 2>/dev/null || exit 1
        mv -- "$phase_tmp" "$candidate_dir/phase.pending" || exit 1
        complete=1
        printf '%s\t%s\t%s\t%s\n' "$candidate_dir" "$candidate_id" "$candidate_token" \
            "$candidate_token_id"
    )
    local create_status=$?

    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    if [[ -n "$saved_hup" ]]; then eval "$saved_hup"; else trap - HUP; fi
    pending_signal="$SSH_ROLLBACK_SIGNAL_PENDING"
    SSH_ROLLBACK_SIGNAL_PENDING=""

    if ((create_status == 0)); then
        IFS=$'\t' read -r state_dir state_id state_token token_id <<< "$state_record"
        token_file="$state_dir/token"
        SSH_ROLLBACK_STATE_DIR="$state_dir"
        SSH_ROLLBACK_STATE_ID="$state_id"
        SSH_ROLLBACK_STATE_TOKEN="$state_token"
        SSH_ROLLBACK_TOKEN_FILE="$token_file"
        SSH_ROLLBACK_TOKEN_ID="$token_id"
        ssh_rollback_state_valid || create_status=1
    fi

    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || return 1
    fi
    ((create_status == 0))
}

ssh_rollback_create_backup() {
    local ssh_config="$1" tmp_file
    ssh_rollback_state_valid || return 1
    SSH_ROLLBACK_BACKUP="$SSH_ROLLBACK_STATE_DIR/sshd_config.backup"
    tmp_file="$SSH_ROLLBACK_STATE_DIR/.backup-${SSH_ROLLBACK_STATE_TOKEN}"
    [[ ! -e "$SSH_ROLLBACK_BACKUP" && ! -L "$SSH_ROLLBACK_BACKUP" ]] || return 1
    if ! (umask 077; set -o noclobber; command cat -- "$ssh_config" > "$tmp_file") 2>/dev/null; then
        return 1
    fi
    chmod 600 "$tmp_file" || return 1
    mv -- "$tmp_file" "$SSH_ROLLBACK_BACKUP" || return 1
    SSH_ROLLBACK_BACKUP_ID=$(ssh_rollback_file_identity "$SSH_ROLLBACK_BACKUP") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_BACKUP" "$SSH_ROLLBACK_BACKUP_ID" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_BACKUP" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
}

ssh_rollback_marker_is_valid() {
    local marker="$1" marker_token="$2" marker_id marker_value
    [[ -n "$marker" && -n "$marker_token" && -f "$marker" && ! -L "$marker" ]] || return 1
    marker_id=$(ssh_rollback_file_identity "$marker") || return 1
    ssh_rollback_owned_file "$marker" "$marker_id" || return 1
    IFS= read -r marker_value < "$marker" || return 1
    [[ "$marker_value" == "$marker_token" ]]
}

ssh_rollback_create_marker() {
    local marker="$1" marker_token="$2" tmp_file marker_id
    ssh_rollback_state_valid || return 1
    [[ "$marker" == "$SSH_ROLLBACK_STATE_DIR/confirmed" && ! -e "$marker" && ! -L "$marker" ]] || return 1
    tmp_file="$SSH_ROLLBACK_STATE_DIR/.confirmed-${marker_token}"
    if ! (umask 077; set -o noclobber; printf '%s\n' "$marker_token" > "$tmp_file") 2>/dev/null; then
        return 1
    fi
    chmod 600 "$tmp_file" || return 1
    mv -- "$tmp_file" "$marker" || return 1
    marker_id=$(ssh_rollback_file_identity "$marker") || return 1
    ssh_rollback_owned_file "$marker" "$marker_id" || return 1
    ssh_rollback_marker_is_valid "$marker" "$marker_token"
}

ssh_rollback_result_is_valid() {
    local result_value result_id
    [[ -n "$SSH_ROLLBACK_RESULT_FILE" && -f "$SSH_ROLLBACK_RESULT_FILE" \
        && ! -L "$SSH_ROLLBACK_RESULT_FILE" ]] || return 1
    result_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_RESULT_FILE") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_RESULT_FILE" "$result_id" || return 1
    IFS= read -r result_value < "$SSH_ROLLBACK_RESULT_FILE" || return 1
    [[ "$result_value" == "${SSH_ROLLBACK_STATE_TOKEN}:rolled-back" ]]
}

ssh_rollback_record_result() {
    local tmp_file result_id
    [[ -n "$SSH_ROLLBACK_STATE_DIR" ]] || return 0
    ssh_rollback_state_valid || return 1
    SSH_ROLLBACK_RESULT_FILE="$SSH_ROLLBACK_STATE_DIR/rolled-back"
    if [[ -e "$SSH_ROLLBACK_RESULT_FILE" || -L "$SSH_ROLLBACK_RESULT_FILE" ]]; then
        ssh_rollback_result_is_valid || return 1
        ssh_rollback_sync_path "$SSH_ROLLBACK_RESULT_FILE" || return 1
        ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
        return $?
    fi
    tmp_file="$SSH_ROLLBACK_STATE_DIR/.rolled-back-${SSH_ROLLBACK_STATE_TOKEN}"
    if ! (umask 077; set -o noclobber; \
        printf '%s\n' "${SSH_ROLLBACK_STATE_TOKEN}:rolled-back" > "$tmp_file") 2>/dev/null; then
        return 1
    fi
    chmod 600 "$tmp_file" || return 1
    mv -- "$tmp_file" "$SSH_ROLLBACK_RESULT_FILE" || return 1
    result_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_RESULT_FILE") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_RESULT_FILE" "$result_id" || return 1
    ssh_rollback_result_is_valid || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_RESULT_FILE" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
}

ssh_rollback_config_is_live() {
    [[ "$1" == "/etc/ssh/sshd_config" ]]
}

ssh_rollback_validate_config() {
    local ssh_config="$1" sshd_bin=""
    ssh_rollback_config_is_live "$ssh_config" || return 0
    if command -v sshd >/dev/null 2>&1; then
        sshd_bin=$(command -v sshd)
    elif [[ -x /usr/sbin/sshd ]]; then
        sshd_bin=/usr/sbin/sshd
    else
        echo -e "${RED}[ERROR]${NC} 找不到 sshd，无法验证 SSH 配置。" >&2
        return 1
    fi
    "$sshd_bin" -t -f "$ssh_config"
}

ssh_rollback_restart_service() {
    local ssh_config="$1"
    ssh_rollback_config_is_live "$ssh_config" || return 0
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
}

ssh_rollback_remove_backup() {
    local backup_file="$1"
    ssh_rollback_backup_is_valid "$backup_file" || return 1
    rm -f -- "$backup_file" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR"
}

ssh_rollback_remove_state() {
    local marker_id="" result_id="" phase phase_id entry state_parent
    [[ -n "$SSH_ROLLBACK_STATE_DIR" ]] || return 0
    ssh_rollback_state_valid || return 1
    [[ ! -e "$SSH_ROLLBACK_BACKUP" && ! -L "$SSH_ROLLBACK_BACKUP" ]] || return 1
    # Persist any preceding backup deletion before removing the completion
    # evidence that proves rollback finished.
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR" || return 1
    for entry in "$SSH_ROLLBACK_STATE_DIR"/* "$SSH_ROLLBACK_STATE_DIR"/.[!.]* \
        "$SSH_ROLLBACK_STATE_DIR"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "$entry" in
            "$SSH_ROLLBACK_TOKEN_FILE"|"$SSH_ROLLBACK_MARKER"|"$SSH_ROLLBACK_RESULT_FILE"|\
            "$SSH_ROLLBACK_STATE_DIR/phase.pending"|"$SSH_ROLLBACK_STATE_DIR/phase.confirmed"|\
            "$SSH_ROLLBACK_STATE_DIR/phase.rolling-back") ;;
            *) return 1 ;;
        esac
    done
    if [[ -n "$SSH_ROLLBACK_MARKER" && -e "$SSH_ROLLBACK_MARKER" ]]; then
        ssh_rollback_marker_is_valid "$SSH_ROLLBACK_MARKER" "$SSH_ROLLBACK_MARKER_TOKEN" || return 1
        marker_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_MARKER") || return 1
        ssh_rollback_owned_file "$SSH_ROLLBACK_MARKER" "$marker_id" || return 1
        rm -f -- "$SSH_ROLLBACK_MARKER" || return 1
    fi
    if [[ -n "$SSH_ROLLBACK_RESULT_FILE" && -e "$SSH_ROLLBACK_RESULT_FILE" ]]; then
        ssh_rollback_result_is_valid || return 1
        result_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_RESULT_FILE") || return 1
        ssh_rollback_owned_file "$SSH_ROLLBACK_RESULT_FILE" "$result_id" || return 1
        rm -f -- "$SSH_ROLLBACK_RESULT_FILE" || return 1
    fi
    phase=$(ssh_rollback_phase_current) || return 1
    phase_id=$(ssh_rollback_file_identity "$SSH_ROLLBACK_STATE_DIR/phase.$phase") || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_STATE_DIR/phase.$phase" "$phase_id" || return 1
    rm -f -- "$SSH_ROLLBACK_STATE_DIR/phase.$phase" || return 1
    ssh_rollback_owned_file "$SSH_ROLLBACK_TOKEN_FILE" "$SSH_ROLLBACK_TOKEN_ID" || return 1
    rm -f -- "$SSH_ROLLBACK_TOKEN_FILE" || return 1
    ssh_rollback_sync_path "$SSH_ROLLBACK_STATE_DIR" || return 1
    [[ -d "$SSH_ROLLBACK_STATE_DIR" && ! -L "$SSH_ROLLBACK_STATE_DIR" \
        && "$(stat -c '%d:%i' "$SSH_ROLLBACK_STATE_DIR" 2>/dev/null)" == "$SSH_ROLLBACK_STATE_ID" ]] || return 1
    state_parent=${SSH_ROLLBACK_STATE_DIR%/*}
    rmdir "$SSH_ROLLBACK_STATE_DIR" || return 1
    ssh_rollback_sync_path "$state_parent"
}

ssh_rollback_discard_unstarted_state() {
    local entry entry_id
    [[ -z "$SSH_ROLLBACK_BACKUP_ID" && -z "$SSH_ROLLBACK_PID" ]] || return 1
    ssh_rollback_state_valid || return 1
    for entry in "$SSH_ROLLBACK_STATE_DIR"/* "$SSH_ROLLBACK_STATE_DIR"/.[!.]* \
        "$SSH_ROLLBACK_STATE_DIR"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "$entry" in
            "$SSH_ROLLBACK_TOKEN_FILE"|"$SSH_ROLLBACK_STATE_DIR/phase.pending") ;;
            "$SSH_ROLLBACK_STATE_DIR/.backup-${SSH_ROLLBACK_STATE_TOKEN}"|\
            "$SSH_ROLLBACK_STATE_DIR/.confirmed-${SSH_ROLLBACK_STATE_TOKEN}"|\
            "$SSH_ROLLBACK_STATE_DIR/.rolled-back-${SSH_ROLLBACK_STATE_TOKEN}")
                entry_id=$(ssh_rollback_file_identity "$entry") || return 1
                ssh_rollback_owned_file "$entry" "$entry_id" || return 1
                rm -f -- "$entry" || return 1
                ;;
            *) return 1 ;;
        esac
    done
    SSH_ROLLBACK_BACKUP=""
    SSH_ROLLBACK_MARKER=""
    SSH_ROLLBACK_RESULT_FILE=""
    ssh_rollback_remove_state
}

# SSH rollback helper: restore original port after atomically claiming rollback.
_ssh_rollback_claimed() {
    local ssh_config="$1"
    local backup_file="$2"
    local original_port="$3"

    [[ "$(ssh_rollback_phase_current 2>/dev/null || true)" == "rolling-back" ]] || return 1
    ssh_rollback_backup_is_valid "$backup_file" || return 1
    command cat -- "$backup_file" > "$ssh_config" || return 1
    ssh_rollback_sync_path "$ssh_config" || return 1
    ssh_rollback_validate_config "$ssh_config" || return 1
    ssh_rollback_restart_service "$ssh_config" || return 1
    ssh_rollback_record_result || return 1
    ssh_rollback_remove_backup "$backup_file" || return 1

    echo -e "\n${YELLOW}[AUTO-ROLLBACK]${NC} SSH 端口已自动恢复为 ${original_port}"
}

_ssh_rollback() {
    local ssh_config="$1" backup_file="$2" original_port="$3" claim_status=0
    ssh_rollback_claim_phase rolling-back || claim_status=$?
    if ((claim_status != 0)); then
        ((claim_status == 2)) && [[ "$SSH_ROLLBACK_CLAIM_RESULT" == "rolling-back" ]] || return 1
    fi
    _ssh_rollback_claimed "$ssh_config" "$backup_file" "$original_port" || return 1
    ssh_rollback_remove_state || return 1
    clear_ssh_rollback_state
}

clear_ssh_rollback_state() {
    SSH_ROLLBACK_PID=""
    SSH_ROLLBACK_ID=""
    SSH_ROLLBACK_CONFIG=""
    SSH_ROLLBACK_BACKUP=""
    SSH_ROLLBACK_BACKUP_ID=""
    SSH_ROLLBACK_ORIGINAL_PORT=""
    SSH_ROLLBACK_MARKER=""
    SSH_ROLLBACK_MARKER_TOKEN=""
    SSH_ROLLBACK_RESULT_FILE=""
    SSH_ROLLBACK_STATE_DIR=""
    SSH_ROLLBACK_STATE_ID=""
    SSH_ROLLBACK_STATE_TOKEN=""
    SSH_ROLLBACK_TOKEN_FILE=""
    SSH_ROLLBACK_TOKEN_ID=""
    SSH_ROLLBACK_CLAIM_RESULT=""
}

stop_ssh_rollback_timer() {
    local current_id=""
    if [[ "$SSH_ROLLBACK_PID" =~ ^[0-9]+$ ]]; then
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        if [[ -n "$current_id" ]]; then
            [[ -n "$SSH_ROLLBACK_ID" && "$current_id" == "$SSH_ROLLBACK_ID" ]] || return 1
            kill "$SSH_ROLLBACK_PID" 2>/dev/null || return 1
        fi
        wait "$SSH_ROLLBACK_PID" 2>/dev/null || true
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        [[ -z "$current_id" || "$current_id" != "$SSH_ROLLBACK_ID" ]] || return 1
    fi
    SSH_ROLLBACK_PID=""
    SSH_ROLLBACK_ID=""
}

start_ssh_rollback_timer() {
    local ssh_config="$1" backup_file="$2" original_port="$3" timeout="$4" marker="$5"
    local backup_id marker_token
    backup_id=$(ssh_rollback_file_identity "$backup_file") || return 1
    SSH_ROLLBACK_BACKUP_ID="$backup_id"
    ssh_rollback_backup_is_valid "$backup_file" || return 1
    [[ "$(ssh_rollback_phase_current 2>/dev/null || true)" == "pending" ]] || return 1
    marker_token="${SSH_ROLLBACK_STATE_TOKEN:-${EUID}-$$-${RANDOM}-${RANDOM}}"
    SSH_ROLLBACK_MARKER_TOKEN="$marker_token"
    (
        local claim_status=0
        sleep "$timeout"
        # Once the timeout has elapsed, rollback claiming and recovery form a
        # critical transaction.  A signal sent to the whole process group also
        # reaches this worker and every external command it starts.  Ignore the
        # interactive termination signals from immediately before the claim
        # through durable result publication and backup removal; the parent
        # receives the same signal, waits for this identity-bound worker, and
        # performs the requested signal exit after cleanup.  Before the sleep
        # completes the worker keeps the default dispositions, so a still-
        # pending timer remains promptly cancellable by stop_ssh_rollback_timer.
        trap '' INT TERM HUP
        ssh_rollback_claim_phase rolling-back || claim_status=$?
        # Only a fully successful claim proves that this worker owns the
        # rollback.  A non-zero result (whether from a durability error or a
        # competing claimant changing the visible phase) carries no claimant
        # identity and must never authorize a second restore.
        if ((claim_status == 0)); then
            _ssh_rollback_claimed "$ssh_config" "$backup_file" "$original_port"
        else
            local observed_phase
            observed_phase=$(ssh_rollback_phase_current 2>/dev/null || true)
            [[ "$observed_phase" == "confirmed" || "$observed_phase" == "rolling-back" ]]
        fi
    ) &
    SSH_ROLLBACK_PID=$!
    SSH_ROLLBACK_ID=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
    SSH_ROLLBACK_CONFIG="$ssh_config"
    SSH_ROLLBACK_BACKUP="$backup_file"
    SSH_ROLLBACK_ORIGINAL_PORT="$original_port"
    SSH_ROLLBACK_MARKER="$marker"
    [[ -n "$SSH_ROLLBACK_STATE_DIR" ]] && \
        SSH_ROLLBACK_RESULT_FILE="$SSH_ROLLBACK_STATE_DIR/rolled-back"
    if [[ -z "$SSH_ROLLBACK_ID" ]]; then
        kill "$SSH_ROLLBACK_PID" 2>/dev/null || true
        wait "$SSH_ROLLBACK_PID" 2>/dev/null || true
        return 1
    fi
}

ssh_rollback_wait_for_timer_completion() {
    local current_id="" wait_status=0
    [[ "$(ssh_rollback_phase_current 2>/dev/null || true)" == "rolling-back" ]] || return 1
    if [[ "$SSH_ROLLBACK_PID" =~ ^[0-9]+$ ]]; then
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        if [[ -n "$current_id" ]]; then
            [[ -n "$SSH_ROLLBACK_ID" && "$current_id" == "$SSH_ROLLBACK_ID" ]] || return 1
        fi
        wait "$SSH_ROLLBACK_PID" || wait_status=$?
        ((wait_status == 0)) || return 1
        current_id=$(cleanup_process_identity "$SSH_ROLLBACK_PID" 2>/dev/null || true)
        [[ -z "$current_id" || "$current_id" != "$SSH_ROLLBACK_ID" ]] || return 1
    fi
    ssh_rollback_result_is_valid || return 1
    [[ ! -e "$SSH_ROLLBACK_BACKUP" && ! -L "$SSH_ROLLBACK_BACKUP" ]]
}

ssh_rollback_confirm() {
    local phase
    if ssh_rollback_claim_phase confirmed; then
        stop_ssh_rollback_timer || return 1
        ssh_rollback_remove_backup "$SSH_ROLLBACK_BACKUP" || return 1
        ssh_rollback_remove_state || return 1
        clear_ssh_rollback_state
        return 0
    fi
    phase=$(ssh_rollback_phase_current 2>/dev/null || true)
    if [[ "$phase" == "rolling-back" ]]; then
        if ! ssh_rollback_wait_for_timer_completion; then
            echo -e "${RED}[ERROR]${NC} 确认输掉回滚竞态，且无法验证回滚完成；状态已保留。" >&2
            return 1
        fi
        ssh_rollback_remove_state || return 1
        clear_ssh_rollback_state
        echo -e "${YELLOW}[ROLLBACK WON]${NC} 确认输掉回滚竞态；已等待并验证回滚完成。" >&2
        return 2
    fi
    echo -e "${RED}[ERROR]${NC} 无法安全提交确认；phase 状态已保留。" >&2
    return 1
}

cleanup_pending_ssh_rollback() {
    local phase claim_status=0
    [[ -n "$SSH_ROLLBACK_PID" || -n "$SSH_ROLLBACK_STATE_DIR" ]] || return 0
    if [[ -n "$SSH_ROLLBACK_STATE_DIR" && -z "$SSH_ROLLBACK_BACKUP_ID" ]]; then
        if [[ -n "$SSH_ROLLBACK_PID" ]]; then
            stop_ssh_rollback_timer || return 1
        fi
        ssh_rollback_discard_unstarted_state || return 1
        clear_ssh_rollback_state
        return 0
    fi
    phase=$(ssh_rollback_phase_current) || return 1
    case "$phase" in
        pending)
            ssh_rollback_claim_phase rolling-back || claim_status=$?
            if ((claim_status != 0)) \
                && ! { ((claim_status == 2)) && [[ "$SSH_ROLLBACK_CLAIM_RESULT" == "rolling-back" ]]; }; then
                phase=$(ssh_rollback_phase_current 2>/dev/null || true)
                [[ "$phase" == "rolling-back" ]] || return 1
                ssh_rollback_wait_for_timer_completion || return 1
            else
                if [[ -n "$SSH_ROLLBACK_PID" ]]; then
                    stop_ssh_rollback_timer || return 1
                fi
                _ssh_rollback_claimed "$SSH_ROLLBACK_CONFIG" "$SSH_ROLLBACK_BACKUP" \
                    "$SSH_ROLLBACK_ORIGINAL_PORT" || return 1
            fi
            ssh_rollback_remove_state || return 1
            ;;
        confirmed)
            if [[ -n "$SSH_ROLLBACK_PID" ]]; then
                stop_ssh_rollback_timer || return 1
            fi
            if [[ -e "$SSH_ROLLBACK_BACKUP" || -L "$SSH_ROLLBACK_BACKUP" ]]; then
                ssh_rollback_remove_backup "$SSH_ROLLBACK_BACKUP" || return 1
            fi
            ssh_rollback_remove_state || return 1
            ;;
        rolling-back)
            if [[ -n "$SSH_ROLLBACK_PID" ]]; then
                ssh_rollback_wait_for_timer_completion || return 1
            elif ! ssh_rollback_result_is_valid; then
                _ssh_rollback_claimed "$SSH_ROLLBACK_CONFIG" "$SSH_ROLLBACK_BACKUP" \
                    "$SSH_ROLLBACK_ORIGINAL_PORT" || return 1
            fi
            ssh_rollback_remove_state || return 1
            ;;
        *) return 1 ;;
    esac
    clear_ssh_rollback_state
}

# 修改 SSH 端口（带自动回滚保护）
change_ssh_port() {
    local ssh_config="/etc/ssh/sshd_config"
    local backup_file=""
    local rollback_marker=""
    local rollback_timeout=120  # 2 minutes to confirm

    # 安全警告框
    clear
    echo -e "${RED}################################################################${NC}"
    echo -e "${RED}#                    高风险操作警告 (WARNING)                  #${NC}"
    echo -e "${RED}################################################################${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  1. 云服务器用户 (阿里云/腾讯云/AWS等)：                     ${RED}#${NC}"
    echo -e "${RED}#${NC}     必须先在网页控制台的【安全组/防火墙】放行新端口！        ${RED}#${NC}"
    echo -e "${RED}#${NC}     (脚本只能修改系统内部防火墙，无法修改云平台安全组)       ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  2. 修改后你有 ${rollback_timeout} 秒时间确认连接是否正常         ${RED}#${NC}"
    echo -e "${RED}#${NC}     如果未确认，端口将自动恢复为原端口 ($CURRENT_SSH)       ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}#${NC}  3. 请新开一个 SSH 窗口测试新端口，然后回来输入 'confirm'   ${RED}#${NC}"
    echo -e "${RED}#${NC}                                                              ${RED}#${NC}"
    echo -e "${RED}################################################################${NC}"
    echo ""

    read -p "我已知晓风险，确认继续修改? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}>>> 操作已取消。${NC}"
        sleep 1
        return
    fi

    echo ""
    read -p "请输入新的 SSH 端口 [当前: $CURRENT_SSH]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    # Security: validate port more strictly
    new_port=$(get_validated_port "$new_port" false) || return

    echo -e "${BLUE}正在修改 SSH 端口...${NC}"

    # Step 1: Create an owned private rollback state and backup BEFORE any changes.
    if ! ssh_rollback_prepare_state; then
        echo -e "${RED}[ERROR]${NC} 无法安全创建 SSH 回滚状态，未修改配置。" >&2
        return 1
    fi
    rollback_marker="$SSH_ROLLBACK_STATE_DIR/confirmed"
    SSH_ROLLBACK_CONFIG="$ssh_config"
    SSH_ROLLBACK_ORIGINAL_PORT="$CURRENT_SSH"
    SSH_ROLLBACK_MARKER="$rollback_marker"
    SSH_ROLLBACK_MARKER_TOKEN="$SSH_ROLLBACK_STATE_TOKEN"
    SSH_ROLLBACK_RESULT_FILE="$SSH_ROLLBACK_STATE_DIR/rolled-back"
    if ! ssh_rollback_create_backup "$ssh_config"; then
        echo -e "${RED}[ERROR]${NC} 无法安全创建 SSH 回滚备份，未修改配置。" >&2
        cleanup_pending_ssh_rollback || \
            echo -e "${RED}[ERROR]${NC} 未能安全清理回滚状态；写锁必须保留。" >&2
        return 1
    fi
    backup_file="$SSH_ROLLBACK_BACKUP"
    echo -e "${GREEN}[BACKUP]${NC} 配置已备份到 $backup_file"

    # Step 2: Modify config
    if grep -q "^Port" "$ssh_config"; then
        if ! sed -i "s/^Port.*/Port $new_port/" "$ssh_config"; then
            _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
                echo -e "${RED}[ERROR]${NC} 配置写入及自动恢复均失败；安全备份已保留。" >&2
            return 1
        fi
    else
        if ! echo "Port $new_port" >> "$ssh_config"; then
            _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
                echo -e "${RED}[ERROR]${NC} 配置写入及自动恢复均失败；安全备份已保留。" >&2
            return 1
        fi
    fi

    if ! ssh_rollback_validate_config "$ssh_config"; then
        echo -e "${RED}[ERROR]${NC} 新 SSH 配置验证失败，正在恢复原配置。" >&2
        _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
            echo -e "${RED}[ERROR]${NC} 自动恢复失败；安全备份已保留在 $backup_file" >&2
        return 1
    fi

    # Step 3: Open firewall for new port
    open_firewall_port "$new_port"

    # Step 4: Start a tracked background rollback timer
    if ! start_ssh_rollback_timer "$ssh_config" "$backup_file" "$CURRENT_SSH" \
        "$rollback_timeout" "$rollback_marker"; then
        echo -e "${RED}[ERROR]${NC} 无法启动 SSH 回滚计时器，正在恢复原配置。" >&2
        _ssh_rollback "$ssh_config" "$backup_file" "$CURRENT_SSH" || \
            echo -e "${RED}[ERROR]${NC} 自动恢复失败；安全备份已保留在 $backup_file" >&2
        return 1
    fi

    # Step 5: Restart SSH service
    echo -e "${BLUE}[INFO]${NC} 重启 SSH 服务..."
    if ! ssh_rollback_restart_service "$ssh_config"; then
        echo -e "${RED}[ERROR]${NC} SSH 服务重启失败，正在恢复原配置。" >&2
        if ! cleanup_pending_ssh_rollback; then
            echo -e "${RED}[ERROR]${NC} 自动恢复失败；安全备份和状态已保留。" >&2
        fi
        return 1
    fi

    # Step 6: Wait for user confirmation
    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  SSH 端口已修改为 $new_port                                     ${NC}"
    echo -e "${YELLOW}║                                                               ${NC}"
    echo -e "${YELLOW}║  请立即在【新窗口】测试: ssh -p $new_port user@server          ${NC}"
    echo -e "${YELLOW}║                                                               ${NC}"
    echo -e "${YELLOW}║  如果连接成功，请在这里输入 'confirm' 保留更改                ${NC}"
    echo -e "${YELLOW}║  如果 ${rollback_timeout} 秒内未确认，端口将自动恢复为 $CURRENT_SSH     ${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local user_confirm=""
    local start_time=$SECONDS
    while [[ $((SECONDS - start_time)) -lt $rollback_timeout ]]; do
        local remaining=$((rollback_timeout - (SECONDS - start_time)))
        echo -ne "\r  剩余时间: ${remaining}s | 输入 'confirm' 确认: "
        if read -t 1 -r user_confirm; then
            break
        fi
    done
    echo ""

    if [[ "$user_confirm" == "confirm" ]]; then
        if ssh_rollback_confirm; then
            echo -e "${GREEN}[SUCCESS]${NC} SSH 端口修改已确认！新端口: $new_port"
        else
            local confirm_status=$?
            ((confirm_status == 2)) || \
                echo -e "${RED}[ERROR]${NC} 无法安全提交确认；回滚状态已保留。" >&2
            return 1
        fi
    else
        # Timeout or cancelled, rollback will happen automatically
        echo -e "${YELLOW}[TIMEOUT]${NC} 未收到确认，将自动回滚..."
        # Force immediate rollback instead of waiting
        if ! cleanup_pending_ssh_rollback; then
            echo -e "${RED}[ERROR]${NC} SSH 自动回滚未完整成功；安全备份和状态已保留。" >&2
            return 1
        fi
    fi

    read -n 1 -s -r -p "按任意键继续..."
}

# 修改 Vision 端口
change_vision_port() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        echo -e "${RED}[ERROR]${NC} Xray 配置文件不存在！"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    read -p "请输入新的 Vision 端口 [当前: $CURRENT_VISION]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    echo -e "${BLUE}正在修改 Vision 端口...${NC}"

    # 使用 jq 修改端口
    if command -v jq &>/dev/null; then
        # 尝试多种 tag 名称
        local tmp_file="${XRAY_CONF}.tmp"
        jq --argjson port "$new_port" '
            (.inbounds[] | select(.tag=="vision_node" or .tag=="vless-reality-vision" or (.settings.clients and .streamSettings.realitySettings)) | .port) |= $port
        ' "$XRAY_CONF" > "$tmp_file" && mv "$tmp_file" "$XRAY_CONF"
    fi

    # 更新节点配置文件
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        if grep -q "^PORT=" "$node_file"; then
            sed -i "s/^PORT=.*/PORT=$new_port/" "$node_file"
        fi
    done

    # 开放防火墙
    open_firewall_port "$new_port"

    # 重启 Xray
    echo -e "${BLUE}[INFO]${NC} 重启 Xray 服务..."
    service_restart xray

    echo -e "${GREEN}修改成功！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 修改 XHTTP 端口
change_xhttp_port() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        echo -e "${RED}[ERROR]${NC} Xray 配置文件不存在！"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    if [[ "$CURRENT_XHTTP" == "N/A" ]]; then
        echo -e "${YELLOW}[WARN]${NC} XHTTP 未启用"
        read -n 1 -s -r -p "按任意键继续..."
        return
    fi

    read -p "请输入新的 XHTTP 端口 [当前: $CURRENT_XHTTP]: " new_port
    [[ -z "$new_port" ]] && return
    validate_port "$new_port" || return

    echo -e "${BLUE}正在修改 XHTTP 端口...${NC}"

    # 使用 jq 修改端口
    if command -v jq &>/dev/null; then
        local tmp_file="${XRAY_CONF}.tmp"
        jq --argjson port "$new_port" '
            (.inbounds[] | select(.tag=="xhttp_node") | .port) |= $port
        ' "$XRAY_CONF" > "$tmp_file" && mv "$tmp_file" "$XRAY_CONF"
    fi

    # 更新节点配置文件
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        if grep -q "^XHTTP_PORT=" "$node_file"; then
            sed -i "s/^XHTTP_PORT=.*/XHTTP_PORT=$new_port/" "$node_file"
        fi
    done

    # 开放防火墙
    open_firewall_port "$new_port"

    # 重启 Xray
    echo -e "${BLUE}[INFO]${NC} 重启 Xray 服务..."
    service_restart xray

    echo -e "${GREEN}修改成功！${NC}"
    read -n 1 -s -r -p "按任意键继续..."
}

# 端口管理菜单
cmd_ports() {
    while true; do
        get_current_ports
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              端口管理面板 (Port Manager)              ${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  服务              端口            状态"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        printf "  ${GREEN}1.${NC} 修改 SSH          ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_SSH" "$(check_port_status "$CURRENT_SSH")"
        printf "  ${GREEN}2.${NC} 修改 Vision       ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_VISION" "$([[ "$CURRENT_VISION" != "N/A" ]] && check_port_status "$CURRENT_VISION" || echo -e "${RED}N/A${NC}")"
        printf "  ${GREEN}3.${NC} 修改 XHTTP        ${YELLOW}%-12s${NC}  %s\n" "$CURRENT_XHTTP" "$([[ "$CURRENT_XHTTP" != "N/A" ]] && check_port_status "$CURRENT_XHTTP" || echo -e "${RED}N/A${NC}")"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} 返回 (Back)"
        echo ""
        read -p "请输入选项 [0-3]: " choice

        case "$choice" in
            1) change_ssh_port ;;
            2) change_vision_port ;;
            3) change_xhttp_port ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ============== 日志查看 ==============

cmd_logs() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              日志查看器 (Log Viewer)                  ${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Xray 日志 (最新 50 行)"
        echo -e "  ${GREEN}2.${NC} Xray 错误日志"
        echo -e "  ${GREEN}3.${NC} SSH 登录日志"
        echo -e "  ${GREEN}4.${NC} Fail2ban 日志"
        echo -e "  ${GREEN}5.${NC} 系统日志"
        echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} 返回 (Back)"
        echo ""
        read -p "请输入选项 [0-5]: " choice

        case "$choice" in
            1)
                echo ""
                echo -e "${CYAN}>>> Xray 日志 (最新 50 行):${NC}"
                echo ""
                if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                    if [[ -f /var/log/xray/access.log ]]; then
                        tail -50 /var/log/xray/access.log
                    else
                        echo "日志文件不存在"
                    fi
                else
                    journalctl -u xray --no-pager -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                echo ""
                echo -e "${CYAN}>>> Xray 错误日志:${NC}"
                echo ""
                if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                    if [[ -f /var/log/xray/error.log ]]; then
                        tail -50 /var/log/xray/error.log
                    else
                        echo "日志文件不存在"
                    fi
                else
                    journalctl -u xray --no-pager -p err -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            3)
                echo ""
                echo -e "${CYAN}>>> SSH 登录日志:${NC}"
                echo ""
                if [[ -f /var/log/auth.log ]]; then
                    grep -E "sshd.*(Accepted|Failed)" /var/log/auth.log 2>/dev/null | tail -30
                elif [[ -f /var/log/secure ]]; then
                    grep -E "sshd.*(Accepted|Failed)" /var/log/secure 2>/dev/null | tail -30
                else
                    journalctl -u ssh -u sshd --no-pager -n 30 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            4)
                echo ""
                echo -e "${CYAN}>>> Fail2ban 日志:${NC}"
                echo ""
                if [[ -f /var/log/fail2ban.log ]]; then
                    grep -E "(Ban|Unban)" /var/log/fail2ban.log 2>/dev/null | tail -30
                else
                    echo "Fail2ban 日志不存在"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            5)
                echo ""
                echo -e "${CYAN}>>> 系统日志 (最新 50 行):${NC}"
                echo ""
                if [[ -f /var/log/syslog ]]; then
                    tail -50 /var/log/syslog
                elif [[ -f /var/log/messages ]]; then
                    tail -50 /var/log/messages
                else
                    journalctl --no-pager -n 50 2>/dev/null || echo "无法读取日志"
                fi
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效${NC}"; sleep 1 ;;
        esac
    done
}

# ============== 独立工具安装 ==============

install_standalone_tools() {
    local bin_dir="/usr/local/bin"

    echo -e "${BLUE}[INFO]${NC} 安装独立工具命令到 ${bin_dir}..."

    # 1. info 命令 - 显示节点信息
    cat > "${bin_dir}/xray-info" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Info Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" info
elif command -v reality-vision &>/dev/null; then
    reality-vision info
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-info"

    # 2. ports 命令 - 端口管理
    cat > "${bin_dir}/xray-ports" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Ports Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" ports
elif command -v reality-vision &>/dev/null; then
    reality-vision ports
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-ports"

    # 3. logs 命令 - 日志查看
    cat > "${bin_dir}/xray-logs" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Logs Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" logs
elif command -v reality-vision &>/dev/null; then
    reality-vision logs
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-logs"

    # 4. bbr 命令
    cat > "${bin_dir}/xray-bbr" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - BBR Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" bbr
elif command -v reality-vision &>/dev/null; then
    reality-vision bbr
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-bbr"

    # 5. swap 命令
    cat > "${bin_dir}/xray-swap" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Swap Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" swap
elif command -v reality-vision &>/dev/null; then
    reality-vision swap
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-swap"

    # 6. warp 命令
    cat > "${bin_dir}/xray-warp" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - WARP Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" warp
elif command -v reality-vision &>/dev/null; then
    reality-vision warp
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-warp"

    # 7. f2b 命令 - Fail2ban
    cat > "${bin_dir}/xray-f2b" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - Fail2ban Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" fail2ban
elif command -v reality-vision &>/dev/null; then
    reality-vision fail2ban
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-f2b"

    # 8. timesync 命令 - 时间同步
    cat > "${bin_dir}/xray-timesync" << 'TOOLEOF'
#!/bin/bash
# Reality Vision - TimeSync Tool
SCRIPT_PATH="/root/reality_vision.sh"
if [[ -f "$SCRIPT_PATH" ]]; then
    bash "$SCRIPT_PATH" timesync
elif command -v reality-vision &>/dev/null; then
    reality-vision timesync
else
    echo "Reality Vision script not found"
    exit 1
fi
TOOLEOF
    chmod +x "${bin_dir}/xray-timesync"

    # 9. 主脚本链接
    if [[ -f "/root/reality_vision.sh" ]]; then
        ln -sf "/root/reality_vision.sh" "${bin_dir}/reality-vision" 2>/dev/null || true
    fi

    echo -e "${GREEN}[OK]${NC} 独立工具已安装！可用命令:"
    echo "  xray-info     - 查看节点信息"
    echo "  xray-ports    - 端口管理"
    echo "  xray-logs     - 日志查看"
    echo "  xray-bbr      - BBR 管理"
    echo "  xray-swap     - Swap 管理"
    echo "  xray-warp     - WARP 管理"
    echo "  xray-f2b      - Fail2ban 管理"
    echo "  xray-timesync - 时间同步管理"
}

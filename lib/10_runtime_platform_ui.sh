# ============== 进程清理 ==============

declare -a CLEANUP_JOB_ROOTS=()
declare -a CLEANUP_TREE_PIDS=()
declare -A CLEANUP_TREE_SEEN=()
declare -A CLEANUP_TREE_IDENTITIES=()
declare -A CLEANUP_TRACKED_GROUPS=()
declare -A CLEANUP_GROUP_LEADER_IDENTITIES=()
CLEANUP_HAS_UNBOUNDED_ROOTS=0
CLEANUP_UNSAFE_TO_UNLOCK=0
CLEANUP_STAT_STATE=""
CLEANUP_STAT_GROUP=""
CLEANUP_STAT_IDENTITY=""

cleanup_read_process_stat() {
    local pid="$1" stat_line rest
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    rest="${stat_line##*) }"
    set -- $rest
    (($# >= 20)) || return 1
    CLEANUP_STAT_STATE="$1"
    CLEANUP_STAT_GROUP="$3"
    CLEANUP_STAT_IDENTITY="${20}"
}

cleanup_process_identity() {
    cleanup_read_process_stat "$1" || return 1
    printf '%s\n' "$CLEANUP_STAT_IDENTITY"
}

cleanup_pid_is_original() {
    local pid="$1"
    [[ -n "${CLEANUP_TREE_IDENTITIES[$pid]:-}" ]] || return 1
    cleanup_read_process_stat "$pid" || return 1
    [[ "$CLEANUP_STAT_IDENTITY" == "${CLEANUP_TREE_IDENTITIES[$pid]}" ]]
}

cleanup_pid_is_live_original() {
    cleanup_pid_is_original "$1" || return 1
    [[ "$CLEANUP_STAT_STATE" != Z && "$CLEANUP_STAT_STATE" != X ]]
}

cleanup_process_group() {
    cleanup_read_process_stat "$1" || return 1
    printf '%s\n' "$CLEANUP_STAT_GROUP"
}

cleanup_track_process_group() {
    local pid="$1" group_id own_group leader_identity registered_root_identity
    registered_root_identity="${CLEANUP_TREE_IDENTITIES[$pid]:-}"
    [[ -n "$registered_root_identity" ]] || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    cleanup_read_process_stat "$pid" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    # The jobs snapshot and the group lookup are separate reads.  Refuse to
    # claim a numeric PID that was reused between them.
    [[ "$CLEANUP_STAT_IDENTITY" == "$registered_root_identity" ]] || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    group_id="$CLEANUP_STAT_GROUP"
    cleanup_read_process_stat "$$" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 0
    }
    own_group="$CLEANUP_STAT_GROUP"

    # Claim only a group whose leader is the registered job root, or our own
    # group when this shell is its leader.  Merely being in a different group
    # does not prove ownership: a child can join an existing external group.
    if [[ "$group_id" == "$pid" ]] \
        || [[ "$group_id" == "$own_group" && "$own_group" == "$$" ]]; then
        cleanup_read_process_stat "$group_id" || {
            CLEANUP_HAS_UNBOUNDED_ROOTS=1
            return 0
        }
        leader_identity="$CLEANUP_STAT_IDENTITY"
        if [[ "$group_id" == "$pid" && "$leader_identity" != "$registered_root_identity" ]]; then
            CLEANUP_HAS_UNBOUNDED_ROOTS=1
            return 0
        fi
        CLEANUP_TRACKED_GROUPS[$group_id]=1
        CLEANUP_GROUP_LEADER_IDENTITIES[$group_id]="$leader_identity"
    else
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
    fi
}

cleanup_list_process_ids() {
    local stat_path pid
    for stat_path in /proc/[0-9]*/stat; do
        [[ -r "$stat_path" ]] || continue
        pid="${stat_path#/proc/}"
        printf '%s\n' "${pid%/stat}"
    done
}

cleanup_group_leader_is_original() {
    local group_id="$1" expected_identity
    expected_identity="${CLEANUP_GROUP_LEADER_IDENTITIES[$group_id]:-}"
    [[ -n "$expected_identity" ]] || return 1
    cleanup_read_process_stat "$group_id" 2>/dev/null || return 1
    [[ "$CLEANUP_STAT_IDENTITY" == "$expected_identity" ]]
}

cleanup_validate_tracked_groups() {
    local group_id valid=0
    for group_id in "${!CLEANUP_TRACKED_GROUPS[@]}"; do
        if ! cleanup_group_leader_is_original "$group_id"; then
            CLEANUP_HAS_UNBOUNDED_ROOTS=1
            valid=1
        fi
    done
    return "$valid"
}

cleanup_collect_process_tree() {
    local pid="$1" identity children="" child
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0

    cleanup_read_process_stat "$pid" || return 0
    identity="$CLEANUP_STAT_IDENTITY"
    if [[ -n "${CLEANUP_TREE_IDENTITIES[$pid]:-}" ]] \
        && [[ "${CLEANUP_TREE_IDENTITIES[$pid]}" != "$identity" ]]; then
        return 0
    fi
    if [[ -z "${CLEANUP_TREE_SEEN[$pid]:-}" ]]; then
        CLEANUP_TREE_SEEN[$pid]=1
        CLEANUP_TREE_IDENTITIES[$pid]="$identity"
        CLEANUP_TREE_PIDS+=("$pid")
    fi

    if [[ -r "/proc/$pid/task/$pid/children" ]]; then
        IFS= read -r children < "/proc/$pid/task/$pid/children" || true
        for child in $children; do
            cleanup_collect_process_tree "$child"
        done
    fi
}

cleanup_collect_process_group() {
    local group_id="$1" pid candidate_identity
    local -a candidate_pids=() candidate_identities=()
    local -a validated_pids=() validated_identities=()
    cleanup_group_leader_is_original "$group_id" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 1
    }

    # Treat the whole /proc scan as provisional.  Nothing discovered here is
    # trusted until the leader identity is checked again after the scan.
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$pid" != "$$" ]] || continue
        cleanup_read_process_stat "$pid" 2>/dev/null || continue
        [[ "$CLEANUP_STAT_GROUP" == "$group_id" ]] || continue
        candidate_pids+=("$pid")
        candidate_identities+=("$CLEANUP_STAT_IDENTITY")
    done < <(cleanup_list_process_ids)

    cleanup_group_leader_is_original "$group_id" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 1
    }

    for ((pid = 0; pid < ${#candidate_pids[@]}; pid++)); do
        candidate_identity="${candidate_identities[$pid]}"
        cleanup_read_process_stat "${candidate_pids[$pid]}" 2>/dev/null || continue
        [[ "$CLEANUP_STAT_GROUP" == "$group_id" \
            && "$CLEANUP_STAT_IDENTITY" == "$candidate_identity" ]] || continue
        validated_pids+=("${candidate_pids[$pid]}")
        validated_identities+=("$candidate_identity")
    done

    # Keep even the revalidated members provisional until one final leader
    # check succeeds, so a scan-time reuse cannot contaminate the tracked tree.
    cleanup_group_leader_is_original "$group_id" || {
        CLEANUP_HAS_UNBOUNDED_ROOTS=1
        return 1
    }
    for ((pid = 0; pid < ${#validated_pids[@]}; pid++)); do
        if [[ -z "${CLEANUP_TREE_SEEN[${validated_pids[$pid]}]:-}" ]]; then
            CLEANUP_TREE_SEEN[${validated_pids[$pid]}]=1
            CLEANUP_TREE_IDENTITIES[${validated_pids[$pid]}]="${validated_identities[$pid]}"
            CLEANUP_TREE_PIDS+=("${validated_pids[$pid]}")
        fi
    done
}

cleanup_tree_has_live_processes() {
    local pid
    for pid in "${CLEANUP_TREE_PIDS[@]}"; do
        cleanup_pid_is_live_original "$pid" && return 0
    done
    return 1
}

cleanup_signal_original_processes() {
    local signal="$1" pid
    # Numeric PGIDs can be reused after collection.  Validate every leader
    # immediately before every STOP/TERM/KILL pass; on uncertainty signal
    # nothing and retain the writer lock.
    cleanup_validate_tracked_groups || return 1
    for pid in "${CLEANUP_TREE_PIDS[@]}"; do
        cleanup_pid_is_original "$pid" || continue
        cleanup_validate_tracked_groups || return 1
        cleanup_send_signal "$signal" "$pid" 2>/dev/null || true
    done
}

cleanup_send_signal() {
    kill -s "$1" "$2"
}

cleanup_refresh_process_tree() {
    local pid group_id
    for group_id in "${!CLEANUP_TRACKED_GROUPS[@]}"; do
        cleanup_collect_process_group "$group_id" || return 1
    done
    local -a known_pids=("${CLEANUP_TREE_PIDS[@]}")
    for pid in "${known_pids[@]}"; do
        cleanup_pid_is_original "$pid" || continue
        cleanup_collect_process_tree "$pid"
    done
}

cleanup_freeze_process_tree() {
    local attempt pid before_count after_count
    for attempt in $(seq 1 20); do
        before_count=${#CLEANUP_TREE_PIDS[@]}
        cleanup_signal_original_processes STOP || return 1
        cleanup_refresh_process_tree || return 1
        cleanup_signal_original_processes STOP || return 1
        after_count=${#CLEANUP_TREE_PIDS[@]}
        ((after_count == before_count)) && return 0
    done
    return 1
}

terminate_background_jobs() {
    local pid attempt
    CLEANUP_JOB_ROOTS=()
    CLEANUP_TREE_PIDS=()
    CLEANUP_TREE_SEEN=()
    CLEANUP_TREE_IDENTITIES=()
    CLEANUP_TRACKED_GROUPS=()
    CLEANUP_GROUP_LEADER_IDENTITIES=()
    CLEANUP_HAS_UNBOUNDED_ROOTS=0

    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] && CLEANUP_JOB_ROOTS+=("$pid")
    done < <(jobs -pr 2>/dev/null || true)
    ((${#CLEANUP_JOB_ROOTS[@]} > 0)) || return 0

    for pid in "${CLEANUP_JOB_ROOTS[@]}"; do
        cleanup_collect_process_tree "$pid"
        cleanup_track_process_group "$pid"
    done
    cleanup_refresh_process_tree || return 1
    cleanup_signal_original_processes TERM || return 1

    for attempt in $(seq 1 20); do
        cleanup_refresh_process_tree || return 1
        cleanup_tree_has_live_processes || break
        sleep 0.1
    done

    if cleanup_tree_has_live_processes; then
        cleanup_freeze_process_tree || {
            cleanup_signal_original_processes KILL || true
            return 1
        }
        cleanup_signal_original_processes KILL || return 1
    fi
    for pid in "${CLEANUP_JOB_ROOTS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    for attempt in $(seq 1 20); do
        cleanup_refresh_process_tree || return 1
        if ! cleanup_tree_has_live_processes; then
            ((CLEANUP_HAS_UNBOUNDED_ROOTS == 0)) && return 0
            return 1
        fi
        sleep 0.05
    done
    return 1
}

# 清理函数，确保脚本退出时清理后台进程和临时文件
cleanup() {
    local jobs_stopped=0 rollback_safe=1
    # 恢复光标
    tput cnorm 2>/dev/null || true
    # SSH rollback is itself a tracked background job.  Let its identity-bound
    # recovery finish before the generic job-tree terminator runs; otherwise a
    # timer that already claimed rolling-back could be killed between restoring
    # the config and publishing its durable result.  Any uncertainty remains
    # fail-closed below and retains the writer lock.
    if declare -F cleanup_pending_ssh_rollback >/dev/null 2>&1; then
        cleanup_pending_ssh_rollback || rollback_safe=0
    fi
    # Terminate, wait for, and reap every remaining background process tree
    # before releasing the writer lock.  If SSH recovery could not be proven,
    # do not risk killing its timer through the generic path; retain the lock
    # and all ambiguous jobs instead.
    if ((rollback_safe)); then
        terminate_background_jobs || jobs_stopped=1
    else
        jobs_stopped=1
    fi
    ((jobs_stopped == 0)) || CLEANUP_UNSAFE_TO_UNLOCK=1
    if ((CLEANUP_UNSAFE_TO_UNLOCK == 0)); then
        lock_release_smart
    else
        printf 'proxy-hub: cleanup could not prove quiescence and rollback completion; retaining the write lock\n' >&2
    fi
}

cleanup_signal() {
    local signal="$1" fallback_status="$2"
    trap - EXIT INT TERM
    cleanup
    kill -s "$signal" "$$" 2>/dev/null || exit "$fallback_status"
    exit "$fallback_status"
}

trap cleanup EXIT
trap 'cleanup_signal INT 130' INT
trap 'cleanup_signal TERM 143' TERM

# ============== Spinner 动画执行器 ==============

# 带 spinner 动画的任务执行器
# 用法: execute_task "命令" "描述" [max_retries]
execute_task() {
    local cmd="$1"
    local desc="$2"
    local max_retries="${3:-3}"
    local log_file="/tmp/xray_task_$$.log"
    local attempt=1
    local i=0

    while [[ $attempt -le $max_retries ]]; do
        echo "" > "$log_file"

        # 后台执行命令
        bash -c "$cmd" > "$log_file" 2>&1 &
        local pid=$!

        # 隐藏光标
        tput civis 2>/dev/null || true

        # 显示 spinner
        while kill -0 $pid 2>/dev/null; do
            local frame="${SPINNER_FRAMES[$((i % 4))]}"
            printf "\r  ${BLUE}[%s]${NC} %s..." "$frame" "$desc"
            ((i++))
            sleep 0.1
        done

        # 恢复光标
        tput cnorm 2>/dev/null || true

        wait $pid
        local status=$?

        # 清除当前行
        printf "\r\033[K"

        if [[ $status -eq 0 ]]; then
            echo -e "  ${GREEN}[OK]${NC}   $desc"
            rm -f "$log_file"
            return 0
        fi

        echo -e "  ${RED}[ERR]${NC}  $desc (attempt $attempt/$max_retries)"

        if [[ $attempt -ge $max_retries ]]; then
            echo -e "  ${RED}Error log:${NC}"
            tail -n 5 "$log_file" 2>/dev/null | sed 's/^/    /'
            rm -f "$log_file"
            return 1
        fi

        ((attempt++))
        sleep 2
    done

    rm -f "$log_file"
    return 1
}

# 简单的 spinner 显示（用于等待操作）
show_spinner() {
    local pid=$1
    local msg="$2"
    local i=0

    tput civis 2>/dev/null || true
    while kill -0 $pid 2>/dev/null; do
        local frame="${SPINNER_FRAMES[$((i % 4))]}"
        printf "\r  ${BLUE}[%s]${NC} %s..." "$frame" "$msg"
        ((i++))
        sleep 0.1
    done
    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
}

# ============== 超时输入函数 ==============

# 交互超时设置
UI_TIMEOUT_SHORT=30   # 简单询问
UI_TIMEOUT_LONG=60    # 复杂操作

# 核心：统一倒计时交互函数
# 用法: read_with_timeout "提示语" "默认值" "超时时间"
# 返回值存储在 USER_INPUT 变量中
USER_INPUT=""

read_with_timeout() {
    local prompt="$1"
    local default="$2"
    local timeout="${3:-$UI_TIMEOUT_SHORT}"
    local input_char=""

    # 清空之前的输入残留 (防止幽灵回车导致秒过)
    while read -r -t 0 2>/dev/null; do read -r -n 1 2>/dev/null; done

    USER_INPUT=""

    # 设定截止时间戳
    local start_time end_time current_time remaining
    start_time=$(date +%s)
    end_time=$((start_time + timeout))

    while true; do
        current_time=$(date +%s)
        remaining=$((end_time - current_time))

        # 如果时间到了，退出循环
        if [[ "$remaining" -le 0 ]]; then
            break
        fi

        # 交互 UI： 提示语 [默认: X] [ 10s ] :
        printf "\r${YELLOW}%s [默认: %s] [ ${RED}%ds${YELLOW} ] : ${NC}" "$prompt" "$default" "$remaining"

        # -t 1 等待一秒，但我们只关心是否按键
        if read -t 1 -n 1 input_char 2>/dev/null; then
            # 用户按下了键
            echo "" # 换行
            if [[ -z "$input_char" ]]; then
                USER_INPUT="$default"
            else
                USER_INPUT="$input_char"
            fi
            return 0
        fi
    done

    # 超时处理
    echo ""
    echo -e "${BLUE}[INFO]${NC} 倒计时结束，使用默认值: ${default}"
    USER_INPUT="$default"
}

# ============== 包管理器状态检查 ==============

# 检查包管理器是否繁忙
is_pkg_manager_busy() {
    case "$PKG_MANAGER" in
        apt)
            pgrep -x apt >/dev/null 2>&1 || \
            pgrep -x apt-get >/dev/null 2>&1 || \
            pgrep -x dpkg >/dev/null 2>&1 || \
            pgrep -f "unattended-upgr" >/dev/null 2>&1
            ;;
        dnf|yum)
            pgrep -x dnf >/dev/null 2>&1 || \
            pgrep -x yum >/dev/null 2>&1 || \
            pgrep -x rpm >/dev/null 2>&1
            ;;
        apk)
            pgrep -x apk >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查 dpkg/rpm 数据库状态
check_pkg_db_status() {
    case "$PKG_MANAGER" in
        apt)
            if ! dpkg --audit >/dev/null 2>&1; then
                echo -e "${RED}[ERROR]${NC} 检测到 dpkg 数据库状态异常！"
                echo -e "${YELLOW}建议执行: 'dpkg --configure -a' 修复系统。${NC}"
                return 1
            fi
            ;;
        dnf|yum)
            if ! rpm --query --all >/dev/null 2>&1; then
                echo -e "${RED}[ERROR]${NC} 检测到 RPM 数据库状态异常！"
                echo -e "${YELLOW}建议执行: 'rpm --rebuilddb' 修复系统。${NC}"
                return 1
            fi
            ;;
    esac
    return 0
}

# 等待包管理器释放
wait_for_pkg_manager() {
    local max_wait=300  # 最长等待 5 分钟
    local waited=0
    local i=0

    if ! is_pkg_manager_busy; then
        return 0
    fi

    echo -e "${BLUE}[INFO]${NC} 检测到系统更新进程正在运行，正在等待释放..."
    tput civis 2>/dev/null || true

    while is_pkg_manager_busy; do
        if [[ $waited -ge $max_wait ]]; then
            tput cnorm 2>/dev/null || true
            echo ""
            echo -e "${YELLOW}[WARN]${NC} 等待超时！"
            echo -n "是否强制终止占用进程? (y/n) [n]: "
            read -r kill_choice
            if [[ "$kill_choice" == "y" || "$kill_choice" == "Y" ]]; then
                case "$PKG_MANAGER" in
                    apt)
                        killall apt apt-get dpkg 2>/dev/null || true
                        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null
                        ;;
                    dnf|yum)
                        killall dnf yum 2>/dev/null || true
                        rm -f /var/run/yum.pid /var/run/dnf.pid 2>/dev/null
                        ;;
                esac
                return 0
            else
                echo -e "${RED}[ERROR]${NC} 用户取消，安装终止。"
                return 1
            fi
        fi

        local frame="${SPINNER_FRAMES[$((i % 4))]}"
        printf "\r  ${BLUE}[%s]${NC} 等待包管理器释放... (%ds)" "$frame" "$waited"
        sleep 1
        ((waited++))
        ((i++))
    done

    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
    echo -e "${GREEN}[OK]${NC} 包管理器已释放"
    return 0
}

# ============== IPv6 SSH 保护 ==============

# 检查当前 SSH 连接方式 (防自杀核心)
check_ssh_connection() {
    # 获取当前 SSH 连接的客户端 IP
    local client_ip="${SSH_CLIENT%% *}"
    if [[ -z "$client_ip" ]]; then
        echo "unknown"
    elif [[ "$client_ip" =~ : ]]; then
        echo "v6" # 当前是 IPv6 连接
    else
        echo "v4" # 当前是 IPv4 连接
    fi
}

# IPv6 操作前安全检查
check_ipv6_ssh_safety() {
    local action="$1"  # disable 或 其他操作

    if [[ "$action" == "disable" ]]; then
        if [[ "$(check_ssh_connection)" == "v6" ]]; then
            echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
            echo -e "${RED}                 [危险操作拦截]                        ${NC}"
            echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}检测到您当前正在通过 IPv6 连接 SSH！${NC}"
            echo -e "${YELLOW}若此时禁用 IPv6，您将立即断开连接且无法重连！${NC}"
            echo -e "${RED}操作已取消。请切换到 IPv4 网络连接 SSH 后再试。${NC}"
            echo ""
            read -n 1 -s -r -p "按任意键返回..."
            return 1
        fi
    fi
    return 0
}

# ============== 包管理器检测 ==============

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt-get update -y"
        PKG_INSTALL="apt-get install -y"
        PKG_CHECK="dpkg -s"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf check-update || true"
        PKG_INSTALL="dnf install -y"
        PKG_CHECK="rpm -q"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum check-update || true"
        PKG_INSTALL="yum install -y"
        PKG_CHECK="rpm -q"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add --no-cache"
        PKG_CHECK="apk info -e"
    else
        echo -e "${RED}[ERROR]${NC} Unsupported package manager"
        echo "Please use Debian/Ubuntu, CentOS/RHEL/Fedora, or Alpine Linux"
        exit 1
    fi
}

# ============== init 系统检测 ==============

detect_init_system() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        # 默认尝试 systemd
        INIT_SYSTEM="systemd"
    fi
}

# ============== 服务管理抽象 ==============

# 启动服务
service_start() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" start
    else
        systemctl start "$svc"
    fi
}

# 停止服务
service_stop() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" stop 2>/dev/null || true
    else
        systemctl stop "$svc" 2>/dev/null || true
    fi
}

# Strict variants are used by transactional lifecycle operations that must
# distinguish a real service-manager failure from an already-stopped service.
service_start_strict() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" start
    else
        systemctl start "$svc"
    fi
}

service_stop_strict() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" stop
    else
        systemctl stop "$svc"
    fi
}

openrc_service_pidfile() {
    local svc="$1" script="${2:-/etc/init.d/$1}" line value="" count=0
    [[ -f "$script" && ! -L "$script" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*pidfile=(.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
            ((++count))
        fi
    done < "$script"
    [[ "$count" == 1 ]] || return 1
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value:1:${#value}-2}"
    fi
    value="${value//'${RC_SVCNAME}'/$svc}"
    value="${value//'$RC_SVCNAME'/$svc}"
    [[ "$value" =~ ^/[A-Za-z0-9_./-]+$ && "$value" != *'..'* ]] || return 1
    printf '%s\n' "$value"
}

service_main_pid() {
    local svc="$1" pid pidfile
    local -a pids=()
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        pidfile=$(openrc_service_pidfile "$svc" 2>/dev/null || true)
        if [[ -n "$pidfile" && -f "$pidfile" && ! -L "$pidfile" ]]; then
            IFS= read -r pid < "$pidfile" || return 1
        else
            if [[ "$svc" == xray ]] && declare -F xray_list_process_ids >/dev/null; then
                mapfile -t pids < <(xray_list_process_ids)
            else
                mapfile -t pids < <(pgrep -x "$svc" 2>/dev/null || true)
            fi
            [[ ${#pids[@]} -eq 1 ]] || return 1
            pid="${pids[0]}"
        fi
    else
        pid=$(systemctl show --property MainPID --value "$svc" 2>/dev/null) || return 1
    fi
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

# 重启服务
service_restart() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" restart
    else
        systemctl restart "$svc"
    fi
}

# 设置开机启动
service_enable() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add "$svc" default 2>/dev/null || true
    else
        systemctl enable "$svc" 2>/dev/null || true
    fi
}

# 取消开机启动
service_disable() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update del "$svc" default 2>/dev/null || true
    else
        systemctl disable "$svc" 2>/dev/null || true
    fi
}

# 检查服务是否运行
service_is_active() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" status &>/dev/null
    else
        systemctl is-active --quiet "$svc" 2>/dev/null
    fi
}

# 显示服务状态
service_status() {
    local svc="$1"
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$svc" status 2>/dev/null || echo "Service $svc is not running"
    else
        systemctl status "$svc" --no-pager 2>/dev/null | head -10 || true
    fi
}

# 初始化包管理器和 init 系统
detect_pkg_manager
detect_init_system

# ============== 多语言支持 ==============

# 获取翻译文本
msg() {
    local key="$1"
    if [[ "$CURRENT_LANG" == "en" ]]; then
        case "$key" in
            "menu_title") echo "VLESS TCP REALITY Vision Management" ;;
            "menu_install") echo "Install Node" ;;
            "menu_info") echo "View Node Info" ;;
            "menu_qr") echo "Show QR Code" ;;
            "menu_status") echo "Service Status" ;;
            "menu_health") echo "Health Check" ;;
            "menu_restart") echo "Restart Service" ;;
            "menu_test_sni") echo "Test SNI Latency" ;;
            "menu_uninstall") echo "Uninstall" ;;
            "menu_lang") echo "Switch Language" ;;
            "menu_exit") echo "Exit" ;;
            "menu_choice") echo "Please enter your choice" ;;
            "menu_invalid") echo "Invalid option, please try again" ;;
            "menu_press_enter") echo "Press Enter to continue..." ;;
            "lang_select") echo "Select Language / 选择语言" ;;
            "lang_zh") echo "Chinese (中文)" ;;
            "lang_en") echo "English" ;;
            "installing") echo "Installing VLESS TCP REALITY Vision..." ;;
            "install_deps") echo "Installing dependencies..." ;;
            "install_xray") echo "Installing Xray..." ;;
            "gen_keys") echo "Generating Reality keys..." ;;
            "testing_sni") echo "Testing all SNI domains for latency..." ;;
            "testing") echo "Testing..." ;;
            "test_progress") echo "Progress" ;;
            "current") echo "Current" ;;
            "sni_timeout") echo "All test domains timed out, using default SNI: www.tesla.com" ;;
            "sni_selected") echo "Selected optimal SNI" ;;
            "sni_multiple") echo "Multiple domains have the same lowest latency" ;;
            "sni_choose") echo "Please choose one" ;;
            "latency") echo "latency" ;;
            "install_complete") echo "Installation complete!" ;;
            "uninstalling") echo "Uninstalling..." ;;
            "uninstall_complete") echo "Uninstall complete" ;;
            "config_not_found") echo "Configuration not found, please install first" ;;
            "run_as_root") echo "Please run this script as root" ;;
            "node_info") echo "VLESS Reality Vision Node Info" ;;
            "node_info_suffix") echo "Node Info" ;;
            "server_addr") echo "Server Address" ;;
            "port") echo "Port" ;;
            "share_link") echo "Share Link" ;;
            "qr_title") echo "Node QR Code (Scan to Import)" ;;
            "qr_tip") echo "Tip: Run 'bash $0 qr' to regenerate QR code" ;;
            "common_cmds") echo "Common commands" ;;
            "view_info") echo "View node info" ;;
            "show_qr") echo "Show QR code" ;;
            "service_status") echo "Service Status" ;;
            "service_restarted") echo "Service restarted" ;;
            "test_complete") echo "Test complete" ;;
            "timeout") echo "timeout" ;;
            "using_sni") echo "Using specified SNI" ;;
            "installed") echo "Installed" ;;
            "not_installed") echo "Not Installed" ;;
            "total_domains") echo "Total domains" ;;
            "best_latency") echo "Best latency" ;;
            "health_check") echo "Health Check" ;;
            "connections") echo "Active Connections" ;;
            "sni_selection_title") echo "SNI Domain Selection" ;;
            "sni_top_results") echo "Top 5 Fastest Domains" ;;
            "sni_auto_select") echo "Auto select best" ;;
            "sni_manual_input") echo "Enter custom domain" ;;
            "sni_custom_test") echo "Test custom domains (comma-separated)" ;;
            "sni_custom_test_hint") echo "Enter domains to test, comma-separated (e.g. a.com,b.com,c.com)" ;;
            "sni_custom_test_done") echo "Custom domain test done, select from the results above" ;;
            "sni_choice_prompt") echo "Your choice" ;;
            "sni_no_results") echo "No test results available" ;;
            "sni_use_default") echo "Use default" ;;
            "sni_input_hint") echo "Enter domain (e.g. www.microsoft.com)" ;;
            "sni_empty_input") echo "Empty input" ;;
            "sni_custom_set") echo "Custom SNI set" ;;
            "sni_testing_custom") echo "Testing connectivity" ;;
            "sni_custom_ok") echo "Domain is reachable" ;;
            "sni_custom_unreachable") echo "Domain may be unreachable, but will use it anyway" ;;
            "sni_invalid_format") echo "Invalid domain format" ;;
            "anytls_sni_note") echo "Note: for plain AnyTLS the SNI is only TLS camouflage (self-signed cert, client uses insecure); latency results are for reference only." ;;
            # 新功能翻译
            "menu_tools") echo "System Tools" ;;
            "menu_warp") echo "WARP Routing" ;;
            "menu_bbr") echo "BBR Management" ;;
            "menu_swap") echo "Swap Management" ;;
            "menu_fail2ban") echo "Fail2ban Management" ;;
            "install_geodata") echo "Installing GeoIP/GeoSite databases..." ;;
            "geodata_updated") echo "GeoData databases updated" ;;
            "xhttp_port") echo "XHTTP Port" ;;
            "vision_port") echo "Vision Port" ;;
            "ipv4_links") echo "IPv4 Links" ;;
            "ipv6_links") echo "IPv6 Links" ;;
            "warp_status") echo "WARP Status" ;;
            "warp_running") echo "Running" ;;
            "warp_stopped") echo "Stopped" ;;
            "warp_install") echo "Install WARP" ;;
            "warp_uninstall") echo "Uninstall WARP" ;;
            "warp_netflix") echo "Netflix Routing" ;;
            "warp_ai") echo "AI Services Routing" ;;
            "bbr_enabled") echo "BBR Enabled" ;;
            "bbr_disabled") echo "BBR Disabled" ;;
            "swap_size") echo "Swap Size" ;;
            "fail2ban_status") echo "Fail2ban Status" ;;
            "script_running") echo "Script is already running!" ;;
            "enable_xhttp") echo "Enable XHTTP protocol? (y/n)" ;;
            "xhttp_enabled") echo "XHTTP protocol enabled" ;;
            "detecting_ip") echo "Detecting server IP..." ;;
            "tools_menu") echo "System Optimization Tools" ;;
            "menu_timesync") echo "Time Sync" ;;
            "timesync_title") echo "System Time Sync" ;;
            "timesync_status") echo "Sync Status" ;;
            "timesync_current") echo "Current Time" ;;
            "timesync_timezone") echo "Timezone" ;;
            "timesync_install") echo "Install & Enable Time Sync" ;;
            "timesync_force") echo "Force Sync Now" ;;
            "timesync_uninstall") echo "Remove Time Sync" ;;
            "timesync_not_installed") echo "Not Installed" ;;
            "timesync_synced") echo "Synchronized" ;;
            "timesync_installing") echo "Installing time sync service..." ;;
            "timesync_installed") echo "Time sync service installed and enabled" ;;
            "timesync_forcing") echo "Forcing time synchronization..." ;;
            "timesync_forced") echo "Time synchronized successfully" ;;
            "timesync_removing") echo "Removing time sync service..." ;;
            "timesync_removed") echo "Time sync service removed" ;;
            "timesync_already") echo "Time sync service is already installed" ;;
            "timesync_ss2022_hint") echo "SS2022 requires accurate system time. Choose how to verify or enable synchronization." ;;
            "timesync_env") echo "Environment" ;;
            "timesync_container_warn") echo "Container environment detected - time sync may not work" ;;
            "timesync_container_type") echo "Container type" ;;
            "timesync_container_detail") echo "Containers share the host kernel clock. Time sync should run on the host." ;;
            "timesync_pve_title") echo "Proxmox VE / LXC solutions" ;;
            "timesync_pve_method1") echo "Method 1: Sync time on the PVE host (recommended)" ;;
            "timesync_pve_host_tip") echo "Run chrony/ntpdate on the PVE host, all containers will inherit the time." ;;
            "timesync_pve_method2") echo "Method 2: Grant SYS_TIME capability to this container" ;;
            "timesync_pve_cap_step1") echo "Edit the container config on the PVE host:" ;;
            "timesync_pve_cap_step2") echo "Add this line:" ;;
            "timesync_pve_cap_step3") echo "Then restart the container and try again." ;;
            "timesync_docker_tip") echo "Run the container with SYS_TIME capability:" ;;
            "timesync_try_anyway") echo "Try to install anyway?" ;;
            "timesync_start_failed") echo "Chrony service failed to start!" ;;
            "timesync_check_log") echo "Error log" ;;
            "timesync_check") echo "Check Time Accuracy (no privileges needed)" ;;
            "timesync_checking") echo "Checking time accuracy via HTTP..." ;;
            "timesync_offset") echo "Time offset" ;;
            "timesync_offset_ok") echo "Time is accurate. SS2022 will work normally." ;;
            "timesync_offset_warn") echo "Time offset is large! SS2022 connections may fail." ;;
            "timesync_offset_fail") echo "Failed to fetch remote time. Check network connectivity." ;;
            "timesync_container_no_host") echo "No host access? You can only verify time, not change it." ;;
            "timesync_seconds") echo "seconds" ;;
            "timesync_skip") echo "Skip" ;;
            "update_ip") echo "Update Node IP" ;;
            "update_ip_detecting") echo "Detecting current public IP..." ;;
            "update_ip_current") echo "Current IP" ;;
            "update_ip_stored") echo "Stored IP" ;;
            "update_ip_no_nodes") echo "No nodes configured" ;;
            "update_ip_no_change") echo "IP has not changed, no update needed" ;;
            "update_ip_changed") echo "IP change detected!" ;;
            "update_ip_updating") echo "Updating node configurations..." ;;
            "update_ip_node_updated") echo "Updated node" ;;
            "update_ip_done") echo "All node IPs updated successfully" ;;
            "update_ip_regen") echo "Regenerating Xray config..." ;;
            "update_ip_restarting") echo "Restarting Xray service..." ;;
            "update_ip_complete") echo "IP update complete! New share links will use the updated IP." ;;
            "update_ip_detect_fail") echo "Failed to detect current public IP" ;;
            # Xray 定时重启
            "xray_restart_title") echo "Proxy Service Periodic Restart" ;;
            "xray_restart_prompt") echo "Enable periodic restart of the proxy service(s)? (recommended for long-running stability)" ;;
            "xray_restart_choose") echo "Choose restart schedule" ;;
            "xray_restart_default") echo "default" ;;
            "xray_restart_daily") echo "Daily at 04:00" ;;
            "xray_restart_12h") echo "Every 12 hours" ;;
            "xray_restart_6h") echo "Every 6 hours" ;;
            "xray_restart_weekly") echo "Weekly (Sun 04:00)" ;;
            "xray_restart_custom") echo "Custom cron expression" ;;
            "xray_restart_cron_hint") echo "Format: 'minute hour day month weekday' (e.g. '0 3 * * *')" ;;
            "xray_restart_cron_prompt") echo "Enter cron expression" ;;
            "xray_restart_cron_invalid") echo "Invalid cron expression, falling back to daily" ;;
            "xray_restart_enabled") echo "Proxy service periodic restart enabled" ;;
            "xray_restart_disabled") echo "Proxy service periodic restart disabled" ;;
            "xray_restart_not_enabled") echo "Periodic restart is not currently enabled" ;;
            "xray_restart_already") echo "Periodic restart already enabled" ;;
            "xray_restart_setup_failed") echo "Failed to set up periodic restart (crontab or systemd unavailable)" ;;
            "xray_restart_status") echo "Status" ;;
            "xray_restart_status_on") echo "Enabled" ;;
            "xray_restart_status_off") echo "Disabled" ;;
            "xray_restart_current") echo "Current schedule" ;;
            "xray_restart_backend") echo "Backend" ;;
            "xray_restart_action_set") echo "Enable / Modify schedule" ;;
            "xray_restart_action_disable") echo "Disable periodic restart" ;;
            "xray_restart_back") echo "Back" ;;
            "xray_release_title") echo "Xray Version / Update" ;;
            "xray_release_show_status") echo "Show version status" ;;
            "xray_release_update_stable") echo "Update to latest stable" ;;
            "xray_release_update_latest") echo "Update to latest release including prerelease" ;;
            "xray_release_install_version") echo "Install specified version" ;;
            "xray_release_latest_stable") echo "Latest stable" ;;
            "xray_release_latest_all") echo "Latest release, including prerelease" ;;
            "xray_release_specify") echo "Specify version" ;;
            "xray_release_version_prompt") echo "Xray version (for example v26.7.11)" ;;
            "xray_release_cancel") echo "Cancel" ;;
            "xray_release_back") echo "Back" ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            "menu_title") echo "VLESS TCP REALITY Vision 管理面板" ;;
            "menu_install") echo "安装节点" ;;
            "menu_info") echo "查看节点信息" ;;
            "menu_qr") echo "显示二维码" ;;
            "menu_status") echo "服务状态" ;;
            "menu_health") echo "健康检查" ;;
            "menu_restart") echo "重启服务" ;;
            "menu_test_sni") echo "测试 SNI 延迟" ;;
            "menu_uninstall") echo "卸载节点" ;;
            "menu_lang") echo "切换语言" ;;
            "menu_exit") echo "退出" ;;
            "menu_choice") echo "请输入选项" ;;
            "menu_invalid") echo "无效选项，请重新输入" ;;
            "menu_press_enter") echo "按 Enter 键继续..." ;;
            "lang_select") echo "Select Language / 选择语言" ;;
            "lang_zh") echo "中文" ;;
            "lang_en") echo "English (英文)" ;;
            "installing") echo "开始安装 VLESS TCP REALITY Vision..." ;;
            "install_deps") echo "安装依赖..." ;;
            "install_xray") echo "安装 Xray..." ;;
            "gen_keys") echo "生成 Reality 密钥..." ;;
            "testing_sni") echo "测试所有 SNI 域名延迟..." ;;
            "testing") echo "测试中..." ;;
            "test_progress") echo "进度" ;;
            "current") echo "当前" ;;
            "sni_timeout") echo "所有测试域名均超时，使用默认 SNI: www.tesla.com" ;;
            "sni_selected") echo "选择最优 SNI" ;;
            "sni_multiple") echo "多个域名具有相同的最低延迟" ;;
            "sni_choose") echo "请选择一个" ;;
            "latency") echo "延迟" ;;
            "install_complete") echo "安装完成！" ;;
            "uninstalling") echo "开始卸载..." ;;
            "uninstall_complete") echo "卸载完成" ;;
            "config_not_found") echo "未找到配置文件，请先运行安装" ;;
            "run_as_root") echo "请使用 root 用户运行此脚本" ;;
            "node_info") echo "VLESS Reality Vision 节点信息" ;;
            "node_info_suffix") echo "节点信息" ;;
            "server_addr") echo "服务器地址" ;;
            "port") echo "端口" ;;
            "share_link") echo "分享链接" ;;
            "qr_title") echo "节点二维码（扫码导入）" ;;
            "qr_tip") echo "提示: 可运行 'bash $0 qr' 重新生成二维码" ;;
            "common_cmds") echo "常用命令" ;;
            "view_info") echo "查看节点信息" ;;
            "show_qr") echo "显示二维码" ;;
            "service_status") echo "服务状态" ;;
            "service_restarted") echo "服务已重启" ;;
            "test_complete") echo "测试完成" ;;
            "timeout") echo "超时" ;;
            "using_sni") echo "使用指定 SNI" ;;
            "installed") echo "已安装" ;;
            "not_installed") echo "未安装" ;;
            "total_domains") echo "域名总数" ;;
            "best_latency") echo "最低延迟" ;;
            "health_check") echo "健康检查" ;;
            "connections") echo "当前连接数" ;;
            "sni_selection_title") echo "SNI 域名选择" ;;
            "sni_top_results") echo "延迟最低的 5 个域名" ;;
            "sni_auto_select") echo "自动选择最佳" ;;
            "sni_manual_input") echo "输入自定义域名" ;;
            "sni_custom_test") echo "测试自定义域名（逗号分隔多个）" ;;
            "sni_custom_test_hint") echo "输入要测试的域名，用逗号分隔（如 a.com,b.com,c.com）" ;;
            "sni_custom_test_done") echo "自定义域名测试完成，请从上方结果中选择" ;;
            "sni_choice_prompt") echo "请选择" ;;
            "sni_no_results") echo "没有可用的测试结果" ;;
            "sni_use_default") echo "使用默认" ;;
            "sni_input_hint") echo "输入域名 (例如 www.microsoft.com)" ;;
            "sni_empty_input") echo "输入为空" ;;
            "sni_custom_set") echo "已设置自定义 SNI" ;;
            "sni_testing_custom") echo "测试连通性" ;;
            "sni_custom_ok") echo "域名可访问" ;;
            "sni_custom_unreachable") echo "域名可能无法访问，但仍会使用" ;;
            "sni_invalid_format") echo "域名格式无效" ;;
            "anytls_sni_note") echo "提示：单独 AnyTLS 的 SNI 仅作 TLS 伪装（自签证书，客户端用 insecure），测速结果仅供参考。" ;;
            # 新功能翻译
            "menu_tools") echo "系统工具" ;;
            "menu_warp") echo "WARP 分流" ;;
            "menu_bbr") echo "BBR 管理" ;;
            "menu_swap") echo "Swap 管理" ;;
            "menu_fail2ban") echo "Fail2ban 管理" ;;
            "install_geodata") echo "安装 GeoIP/GeoSite 数据库..." ;;
            "geodata_updated") echo "GeoData 数据库已更新" ;;
            "xhttp_port") echo "XHTTP 端口" ;;
            "vision_port") echo "Vision 端口" ;;
            "ipv4_links") echo "IPv4 链接" ;;
            "ipv6_links") echo "IPv6 链接" ;;
            "warp_status") echo "WARP 状态" ;;
            "warp_running") echo "运行中" ;;
            "warp_stopped") echo "已停止" ;;
            "warp_install") echo "安装 WARP" ;;
            "warp_uninstall") echo "卸载 WARP" ;;
            "warp_netflix") echo "Netflix 分流" ;;
            "warp_ai") echo "AI 服务分流" ;;
            "bbr_enabled") echo "BBR 已启用" ;;
            "bbr_disabled") echo "BBR 未启用" ;;
            "swap_size") echo "Swap 大小" ;;
            "fail2ban_status") echo "Fail2ban 状态" ;;
            "script_running") echo "脚本已在运行中！" ;;
            "enable_xhttp") echo "是否启用 XHTTP 协议？(y/n)" ;;
            "xhttp_enabled") echo "XHTTP 协议已启用" ;;
            "detecting_ip") echo "检测服务器 IP..." ;;
            "tools_menu") echo "系统优化工具" ;;
            "menu_timesync") echo "时间同步" ;;
            "timesync_title") echo "系统时间同步" ;;
            "timesync_status") echo "同步状态" ;;
            "timesync_current") echo "当前时间" ;;
            "timesync_timezone") echo "时区" ;;
            "timesync_install") echo "安装并启用时间同步" ;;
            "timesync_force") echo "立即强制同步" ;;
            "timesync_uninstall") echo "卸载时间同步" ;;
            "timesync_not_installed") echo "未安装" ;;
            "timesync_synced") echo "已同步" ;;
            "timesync_installing") echo "正在安装时间同步服务..." ;;
            "timesync_installed") echo "时间同步服务已安装并启用" ;;
            "timesync_forcing") echo "正在强制同步时间..." ;;
            "timesync_forced") echo "时间同步成功" ;;
            "timesync_removing") echo "正在卸载时间同步服务..." ;;
            "timesync_removed") echo "时间同步服务已卸载" ;;
            "timesync_already") echo "时间同步服务已安装" ;;
            "timesync_ss2022_hint") echo "SS2022 需要精确的系统时间，请选择校验或启用时间同步。" ;;
            "timesync_env") echo "运行环境" ;;
            "timesync_container_warn") echo "检测到容器环境 - 时间同步可能无法工作" ;;
            "timesync_container_type") echo "容器类型" ;;
            "timesync_container_detail") echo "容器与宿主机共享内核时钟，时间同步应在宿主机上进行。" ;;
            "timesync_pve_title") echo "Proxmox VE / LXC 解决方案" ;;
            "timesync_pve_method1") echo "方法一: 在 PVE 宿主机上同步时间 (推荐)" ;;
            "timesync_pve_host_tip") echo "在 PVE 宿主机运行 chrony/ntpdate，所有容器自动继承。" ;;
            "timesync_pve_method2") echo "方法二: 给此容器授权 SYS_TIME 能力" ;;
            "timesync_pve_cap_step1") echo "在 PVE 宿主机上编辑容器配置:" ;;
            "timesync_pve_cap_step2") echo "添加以下行:" ;;
            "timesync_pve_cap_step3") echo "然后重启容器，再次尝试安装。" ;;
            "timesync_docker_tip") echo "使用 SYS_TIME 能力运行容器:" ;;
            "timesync_try_anyway") echo "仍然尝试安装？" ;;
            "timesync_start_failed") echo "Chrony 服务启动失败！" ;;
            "timesync_check_log") echo "错误日志" ;;
            "timesync_check") echo "检查时间准确度 (无需特权)" ;;
            "timesync_checking") echo "正在通过 HTTP 校验时间..." ;;
            "timesync_offset") echo "时间偏差" ;;
            "timesync_offset_ok") echo "时间准确，SS2022 可正常工作。" ;;
            "timesync_offset_warn") echo "时间偏差较大！SS2022 连接可能失败。" ;;
            "timesync_offset_fail") echo "无法获取远程时间，请检查网络连接。" ;;
            "timesync_container_no_host") echo "没有宿主机权限？只能校验时间，无法修改。" ;;
            "timesync_seconds") echo "秒" ;;
            "timesync_skip") echo "跳过" ;;
            "update_ip") echo "更新节点 IP" ;;
            "update_ip_detecting") echo "正在检测当前公网 IP..." ;;
            "update_ip_current") echo "当前 IP" ;;
            "update_ip_stored") echo "已存储 IP" ;;
            "update_ip_no_nodes") echo "未配置任何节点" ;;
            "update_ip_no_change") echo "IP 未变更，无需更新" ;;
            "update_ip_changed") echo "检测到 IP 变更！" ;;
            "update_ip_updating") echo "正在更新节点配置..." ;;
            "update_ip_node_updated") echo "已更新节点" ;;
            "update_ip_done") echo "所有节点 IP 已更新完成" ;;
            "update_ip_regen") echo "正在重新生成 Xray 配置..." ;;
            "update_ip_restarting") echo "正在重启 Xray 服务..." ;;
            "update_ip_complete") echo "IP 更新完成！分享链接将使用新的 IP 地址。" ;;
            "update_ip_detect_fail") echo "无法检测当前公网 IP" ;;
            # Xray 定时重启
            "xray_restart_title") echo "代理服务定时重启" ;;
            "xray_restart_prompt") echo "是否启用代理服务定时重启？（长期运行建议启用）" ;;
            "xray_restart_choose") echo "请选择重启频率" ;;
            "xray_restart_default") echo "默认" ;;
            "xray_restart_daily") echo "每日一次 (04:00)" ;;
            "xray_restart_12h") echo "每 12 小时一次" ;;
            "xray_restart_6h") echo "每 6 小时一次" ;;
            "xray_restart_weekly") echo "每周一次 (周日 04:00)" ;;
            "xray_restart_custom") echo "自定义 cron 表达式" ;;
            "xray_restart_cron_hint") echo "格式: '分 时 日 月 周'（例如 '0 3 * * *' 表示每日 03:00）" ;;
            "xray_restart_cron_prompt") echo "请输入 cron 表达式" ;;
            "xray_restart_cron_invalid") echo "cron 表达式无效，已回退到默认（每日）" ;;
            "xray_restart_enabled") echo "已启用代理服务定时重启" ;;
            "xray_restart_disabled") echo "已禁用代理服务定时重启" ;;
            "xray_restart_not_enabled") echo "当前未启用定时重启" ;;
            "xray_restart_already") echo "已启用定时重启" ;;
            "xray_restart_setup_failed") echo "定时重启配置失败（crontab 或 systemd 不可用）" ;;
            "xray_restart_status") echo "状态" ;;
            "xray_restart_status_on") echo "已启用" ;;
            "xray_restart_status_off") echo "未启用" ;;
            "xray_restart_current") echo "当前计划" ;;
            "xray_restart_backend") echo "后端" ;;
            "xray_restart_action_set") echo "启用 / 修改计划" ;;
            "xray_restart_action_disable") echo "禁用定时重启" ;;
            "xray_restart_back") echo "返回" ;;
            "xray_release_title") echo "Xray 版本 / 更新" ;;
            "xray_release_show_status") echo "显示版本状态" ;;
            "xray_release_update_stable") echo "更新到最新稳定版" ;;
            "xray_release_update_latest") echo "更新到最新版本（含预发布版）" ;;
            "xray_release_install_version") echo "安装指定版本" ;;
            "xray_release_latest_stable") echo "最新稳定版" ;;
            "xray_release_latest_all") echo "最新版本（含预发布版）" ;;
            "xray_release_specify") echo "指定版本" ;;
            "xray_release_version_prompt") echo "Xray 版本（例如 v26.7.11）" ;;
            "xray_release_cancel") echo "取消" ;;
            "xray_release_back") echo "返回" ;;
            *) echo "$key" ;;
        esac
    fi
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

is_root() { [[ "${EUID}" -eq 0 ]]; }

is_port_free() {
    local port="$1"
    local transport="${2:-tcp}"
    local tcp_busy=false udp_busy=false

    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
    case "$transport" in
        tcp|udp|both) ;;
        *) return 1 ;;
    esac

    # 更精确的端口匹配：检查 :port 结尾，避免 80 匹配 8080。
    if [[ "$transport" == "tcp" || "$transport" == "both" ]]; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$" && tcp_busy=true
    fi
    if [[ "$transport" == "udp" || "$transport" == "both" ]]; then
        ss -lnu 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$" && udp_busy=true
    fi

    ! $tcp_busy && ! $udp_busy
}

# ============== 多节点管理 ==============

# 初始化节点目录
init_nodes_dir() {
    mkdir -p "$NODES_DIR"
    chmod 700 "$NODES_DIR"
}

# 获取节点配置文件路径
get_node_file() {
    local node_name="$1"
    echo "${NODES_DIR}/${node_name}.env"
}

# 列出所有节点
list_nodes() {
    local nodes=()
    if [[ -d "$NODES_DIR" ]]; then
        for f in "$NODES_DIR"/*.env; do
            [[ -f "$f" ]] || continue
            local name
            name=$(basename "$f" .env)
            nodes+=("$name")
        done
    fi
    echo "${nodes[@]}"
}

# 获取节点数量
count_nodes() {
    local count=0
    if [[ -d "$NODES_DIR" ]]; then
        count=$(find "$NODES_DIR" -maxdepth 1 -name "*.env" 2>/dev/null | wc -l)
    fi
    echo "$count"
}

# 检查节点是否存在
node_exists() {
    local node_name="$1"
    [[ -f "$(get_node_file "$node_name")" ]]
}

# 生成随机节点名称
generate_random_name() {
    echo "node_$(openssl rand -hex 4)"
}

# 交互式输入节点名称
prompt_node_name() {
    local default_name
    default_name=$(generate_random_name)

    echo "" >/dev/tty
    echo -e "${CYAN}Enter node name (press Enter for random):${NC}" >/dev/tty
    echo -e "${CYAN}输入节点名称（直接回车使用随机名称）:${NC}" >/dev/tty
    echo -n "  [$default_name]: " >/dev/tty
    read -r input_name </dev/tty

    local node_name="${input_name:-$default_name}"

    # 清理非法字符，只保留字母、数字、下划线、短横线
    node_name=$(echo "$node_name" | tr -cd 'a-zA-Z0-9_-')

    # 如果名称已存在，添加后缀
    local base_name="$node_name"
    local counter=1
    while node_exists "$node_name"; do
        node_name="${base_name}_${counter}"
        ((counter++))
    done

    echo "$node_name"
}

# 选择节点（交互式）
select_node() {
    local nodes
    read -ra nodes <<< "$(list_nodes)"
    local count=${#nodes[@]}

    if [[ $count -eq 0 ]]; then
        log_error "$(msg config_not_found)"
        return 1
    fi

    if [[ $count -eq 1 ]]; then
        CURRENT_NODE_NAME="${nodes[0]}"
        return 0
    fi

    echo "" >/dev/tty
    echo -e "${CYAN}Available nodes / 可用节点:${NC}" >/dev/tty
    echo "" >/dev/tty

    local i=1
    for node in "${nodes[@]}"; do
        local node_file
        node_file=$(get_node_file "$node")
        # 使用安全的配置加载（防止命令注入）
        safe_load_node_config "$node_file"
        # 根据协议类型显示对应的端口
        local display_port=""
        local proto="${PROTOCOL_TYPE:-vision}"
        local display_info=""
        if [[ "$proto" == "shadowsocks" ]]; then
            display_port="${PORT:-N/A}"
            display_info="Method: ${SS_METHOD:-N/A}"
        elif [[ "$proto" == "hysteria2" ]]; then
            display_port="${PORT:-N/A} (UDP)"
            display_info="Hysteria2"
        elif [[ "$proto" == "xhttp" ]]; then
            display_port="${XHTTP_PORT:-N/A}"
            display_info="SNI: $SNI"
        elif [[ "$proto" == "both" ]]; then
            display_port="${PORT:-}/${XHTTP_PORT:-}"
            display_info="SNI: $SNI"
        else
            display_port="${PORT:-N/A}"
            display_info="SNI: $SNI"
        fi
        echo -e "  ${GREEN}$i.${NC} $node (Port: $display_port, $display_info)" >/dev/tty
        ((i++))
    done

    echo "" >/dev/tty
    echo -n "  Select node / 选择节点 [1-$count]: " >/dev/tty
    read -r choice </dev/tty

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $count ]]; then
        CURRENT_NODE_NAME="${nodes[$((choice - 1))]}"
    else
        CURRENT_NODE_NAME="${nodes[0]}"
    fi

    return 0
}

# 加载语言设置
load_lang() {
    if [[ -f "$LANG_FILE" ]]; then
        CURRENT_LANG=$(cat "$LANG_FILE")
    fi
}

# 保存语言设置
save_lang() {
    echo "$CURRENT_LANG" > "$LANG_FILE"
    chmod 600 "$LANG_FILE"
}

# 语言选择界面
select_language() {
    clear
    {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${YELLOW}Select Language / 选择语言${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}1.${NC} 中文 (Chinese)                                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}2.${NC} English                                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -n "   请选择 / Please choose [1-2]: "
    } >/dev/tty
    read -r lang_choice </dev/tty

    case "$lang_choice" in
        1)
            CURRENT_LANG="zh"
            ;;
        2)
            CURRENT_LANG="en"
            ;;
        *)
            CURRENT_LANG="zh"
            ;;
    esac
    save_lang
}

# Resolve a temporary parent that cannot be renamed by an unrelated user:
# either a private directory owned by this process UID or a root-owned sticky
# directory such as /tmp.
secure_resolve_tmp_parent() {
    local candidate="${1:-${TMPDIR:-/tmp}}" resolved current owner mode
    [[ "$candidate" != *$'\n'* && "$candidate" != *$'\r'* &&
       -d "$candidate" && ! -L "$candidate" && -w "$candidate" ]] || return 1
    resolved=$(cd -P -- "$candidate" 2>/dev/null && pwd) || return 1
    current="$resolved"
    while :; do
        [[ -d "$current" && ! -L "$current" ]] || return 1
        owner=$(stat -c '%u' "$current" 2>/dev/null) || return 1
        mode=$(stat -c '%a' "$current" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]+$ ]] || return 1
        if [[ "$owner" == "$EUID" || "$owner" == 0 ]] && (((8#$mode & 022) == 0)); then
            :
        elif [[ "$owner" == 0 ]] && (((8#$mode & 01000) != 0)); then
            :
        else
            return 1
        fi
        [[ "$current" == / ]] && break
        current=$(dirname "$current") || return 1
    done
    SECURE_TMP_PARENT="$resolved"
}

identity_bound_tmp_create() {
    local parent="$1" prefix="$2" path owner identity
    [[ "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    secure_resolve_tmp_parent "$parent" || return 1
    parent="$SECURE_TMP_PARENT"
    path=$(mktemp -d "${parent%/}/${prefix}XXXXXXXX") || return 1
    [[ -d "$path" && ! -L "$path" ]] || { rmdir -- "$path" 2>/dev/null || true; return 1; }
    owner=$(stat -c '%u' "$path" 2>/dev/null) || { rmdir -- "$path"; return 1; }
    [[ "$owner" == "$EUID" ]] || { rmdir -- "$path"; return 1; }
    chmod 0700 "$path" || { rmdir -- "$path"; return 1; }
    identity=$(stat -c '%d:%i' "$path" 2>/dev/null) || { rmdir -- "$path"; return 1; }
    IDENTITY_TMP_PATH="$path"
    IDENTITY_TMP_ID="$identity"
    IDENTITY_TMP_PARENT="$parent"
}

identity_bound_tmp_intact() {
    local path="$1" expected_id="$2" parent="$3" prefix="$4" owner current_id
    [[ "$path" == "${parent%/}/${prefix}"* && -d "$path" && ! -L "$path" ]] || return 1
    owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
    current_id=$(stat -c '%d:%i' "$path" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$current_id" == "$expected_id" ]]
}

identity_bound_tmp_cleanup() {
    local path="$1" expected_id="$2" parent="$3" prefix="$4"
    [[ -n "$path" ]] || return 0
    identity_bound_tmp_intact "$path" "$expected_id" "$parent" "$prefix" || return 1
    rm -rf -- "$path"
}

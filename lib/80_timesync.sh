# ============== 时间同步管理 ==============

# 检测虚拟化/容器类型
# 返回: none, lxc, docker, openvz, kvm, vmware, 等
detect_virt_type() {
    # 优先使用 systemd-detect-virt
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        echo "$virt"
        return
    fi
    # 手动检测
    if [[ -f /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q "^container=lxc"; then
        echo "lxc"
    elif [[ -f /.dockerenv ]]; then
        echo "docker"
    elif [[ -d /proc/vz ]] && [[ ! -d /proc/bc ]]; then
        echo "openvz"
    else
        echo "none"
    fi
}

# 检查是否在容器环境中运行
is_container_env() {
    local virt
    virt=$(detect_virt_type)
    case "$virt" in
        lxc|lxc-libvirt|docker|podman|openvz|containerd|systemd-nspawn)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============== 服务沙箱加固 ==============
#
# Xray 与 sing-box 以 root 运行，却只需要绑定端口和操作网络。加固通过 systemd drop-in
# 收窄它们的权限，而不改动服务定义本身：Xray 的 unit 由带 managed marker 的原子发布
# 逻辑管理，往里加指令会破坏那套"是否为脚本管理内容"的判定；drop-in 可以独立增删。
#
# 两条约束决定了实现：
#   1. 需要挂载命名空间的指令（ProtectSystem / PrivateTmp 等）在 LXC、OpenVZ 这类
#      容器里常常直接以 226/NAMESPACE 失败，而便宜的 VPS 很多就是容器。所以容器里
#      只下发不依赖命名空间的核心集合。
#   2. 即使这样也无法穷举所有宿主环境，所以加固必须可验证、可自动撤销：只对已经
#      在运行的服务下发，重启后确认仍然 active，否则删除 drop-in、再次重启恢复原状，
#      并记下跳过标记，不在每次装节点时重复尝试。
SYSTEMD_DROPIN_ROOT="/etc/systemd/system"
SERVICE_HARDENING_STATE_DIR="/etc/proxy-hub"
SERVICE_HARDENING_MIN_SYSTEMD=235

service_hardening_dropin() {
    printf '%s/%s.service.d/10-proxy-hub-hardening.conf' "$SYSTEMD_DROPIN_ROOT" "$1"
}

service_hardening_skip_marker() {
    printf '%s/hardening-%s.skip' "$SERVICE_HARDENING_STATE_DIR" "$1"
}

# 本机是否适用加固：仅 systemd，且版本足够新。
service_hardening_applicable() {
    local version
    [[ "${INIT_SYSTEM:-}" != "openrc" ]] || return 1
    version=$(systemd_version) || return 1
    (( version >= SERVICE_HARDENING_MIN_SYSTEMD ))
}

# 是否运行在容器内。探测工具缺失时按"是"处理：宁可少加几条指令，也不让服务起不来。
service_hardening_in_container() {
    command -v systemd-detect-virt >/dev/null 2>&1 || return 0
    systemd-detect-virt --container --quiet 2>/dev/null
}

# 输出某个服务的 drop-in 内容。
service_hardening_render() {
    local svc="$1"
    cat <<'CORE'
# proxy-hub-managed: hardening-v1
[Service]
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
SystemCallArchitectures=native
CORE
    service_hardening_in_container && return 0
    cat <<'NAMESPACED'
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
NAMESPACED
    # ProtectSystem=full 把 /usr 变成只读，而 sing-box 的 ACME 数据目录在
    # /usr/local/etc/sing-box 下，必须显式放行（"-" 表示目录不存在时忽略）。
    [[ "$svc" == "$SINGBOX_SERVICE" ]] && printf 'ReadWritePaths=-%s\n' "$SINGBOX_DIR"
    return 0
}

service_hardening_is_applied() {
    [[ -f "$(service_hardening_dropin "$1")" ]]
}

service_hardening_remove() {
    local dropin
    dropin=$(service_hardening_dropin "$1")
    [[ -e "$dropin" ]] || return 0
    rm -f -- "$dropin"
    rmdir -- "$(dirname "$dropin")" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

# 为一个正在运行的服务下发加固并验证。
# Usage: service_hardening_ensure SERVICE [force]
# 返回: 0 已加固（或本来就已加固）；1 不适用 / 服务未运行 / 曾经失败已跳过；
#       2 下发后服务起不来，已自动撤销并恢复
service_hardening_ensure() {
    local svc="$1" force="${2:-}" dropin tmp marker
    service_hardening_applicable || return 1
    dropin=$(service_hardening_dropin "$svc")
    marker=$(service_hardening_skip_marker "$svc")
    [[ -f "$dropin" ]] && return 0
    [[ -e "$marker" && "$force" != "force" ]] && return 1
    service_is_active "$svc" || return 1

    mkdir -p -- "$(dirname "$dropin")" || return 1
    tmp=$(mktemp "${dropin}.XXXXXXXX") || return 1
    service_hardening_render "$svc" >"$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$dropin" || {
        rm -f -- "$tmp"
        return 1
    }
    systemctl daemon-reload 2>/dev/null || true

    if service_restart "$svc" >/dev/null 2>&1 && sleep 1 && service_is_active "$svc"; then
        rm -f -- "$marker"
        log_info "$(t2 "已为 $svc 启用服务沙箱加固" "Service sandbox hardening enabled for $svc")"
        return 0
    fi

    # 这台机器上的 systemd/内核不接受这组指令：撤销并恢复，服务可用性优先。
    service_hardening_remove "$svc"
    service_restart "$svc" >/dev/null 2>&1 || true
    mkdir -p -- "$SERVICE_HARDENING_STATE_DIR" 2>/dev/null && : >"$marker"
    log_warn "$(t2 "$svc 在沙箱加固下无法启动，已自动撤销加固并恢复服务（常见于容器型 VPS）" \
        "$svc could not start under sandbox hardening; it was reverted and the service restored (common on container VPSes)")"
    return 2
}

# 检查系统是否有修改时钟的权限 (CAP_SYS_TIME)
check_time_capability() {
    # 方法1: 尝试无害的 adjtimex 查询
    if command -v adjtimex &>/dev/null; then
        adjtimex --print &>/dev/null && return 0
    fi
    # 方法2: 检查 /proc/1/status 的 CapEff (bit 25 = CAP_SYS_TIME)
    if [[ -f /proc/1/status ]]; then
        local cap_eff
        cap_eff=$(grep "^CapEff:" /proc/1/status 2>/dev/null | awk '{print $2}')
        if [[ -n "$cap_eff" ]]; then
            # CAP_SYS_TIME = bit 25 = 0x2000000
            local cap_dec
            cap_dec=$(printf "%d" "0x$cap_eff" 2>/dev/null || echo 0)
            if (( cap_dec & 0x2000000 )); then
                return 0
            else
                return 1
            fi
        fi
    fi
    # 方法3: 尝试直接执行 chronyd 测试 (最可靠的检测)
    # 无法判断时默认假设有权限, 让后续操作自然失败并捕获
    return 0
}

# 检查 chrony 是否已安装
is_timesync_installed() {
    command -v chronyd &>/dev/null
}

# 获取时间同步状态
get_timesync_status() {
    if ! is_timesync_installed; then
        echo "not_installed"
        return
    fi
    if service_is_active chronyd 2>/dev/null || service_is_active chrony 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 获取 chrony 服务名 (不同发行版名称不同)
get_chrony_service_name() {
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        echo "chrony"
    else
        echo "chronyd"
    fi
}

# 显示容器环境时间同步的提示信息
show_container_timesync_hint() {
    local virt
    virt=$(detect_virt_type)
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}⚠${NC}  $(msg timesync_container_warn)"
    echo -e "  $(msg timesync_container_type): ${CYAN}${virt}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  $(msg timesync_container_detail)"
    echo ""
    if [[ "$virt" == "lxc" ]] || [[ "$virt" == "lxc-libvirt" ]]; then
        echo -e "  ${BLUE}$(msg timesync_pve_title):${NC}"
        echo ""
        echo -e "  ${GREEN}$(msg timesync_pve_method1):${NC}"
        echo -e "    $(msg timesync_pve_host_tip)"
        echo ""
        echo -e "  ${GREEN}$(msg timesync_pve_method2):${NC}"
        echo -e "    $(msg timesync_pve_cap_step1)"
        echo -e "    ${CYAN}nano /etc/pve/lxc/<CTID>.conf${NC}"
        echo -e "    $(msg timesync_pve_cap_step2)"
        echo -e "    ${CYAN}lxc.cap.keep: sys_time${NC}"
        echo -e "    $(msg timesync_pve_cap_step3)"
        echo ""
    elif [[ "$virt" == "docker" ]] || [[ "$virt" == "podman" ]]; then
        echo -e "  ${BLUE}Docker/Podman:${NC}"
        echo -e "    $(msg timesync_docker_tip)"
        echo -e "    ${CYAN}docker run --cap-add SYS_TIME ...${NC}"
        echo ""
    fi
    echo -e "  ${GREEN}$(msg timesync_container_no_host)${NC}"
    echo -e "    $(msg timesync_check) → $(msg menu_choice) 3"
    echo ""
}

# 安装并启用时间同步
timesync_install() {
    echo ""

    # 容器环境检测
    if is_container_env && ! check_time_capability; then
        show_container_timesync_hint
        echo -n "  $(msg timesync_try_anyway) [y/N]: "
        read -r try_anyway
        if [[ ! "$try_anyway" =~ ^[Yy]$ ]]; then
            return
        fi
        echo ""
    fi

    if is_timesync_installed; then
        log_info "$(msg timesync_already)"
        local svc_name
        svc_name=$(get_chrony_service_name)
        if ! service_is_active "$svc_name" 2>/dev/null; then
            log_info "$(msg timesync_installing)"
            service_enable "$svc_name"
            if ! service_start "$svc_name" 2>/dev/null; then
                timesync_handle_start_failure
                return
            fi
            log_info "$(msg timesync_installed)"
        fi
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    log_info "$(msg timesync_installing)"

    # 安装 chrony
    case "$PKG_MANAGER" in
        apt)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y chrony >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y chrony >/dev/null 2>&1
            ;;
        yum)
            yum install -y chrony >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache chrony >/dev/null 2>&1
            ;;
    esac

    # 停用 systemd-timesyncd 避免冲突 (仅 systemd 系统)
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
            systemctl stop systemd-timesyncd 2>/dev/null || true
            systemctl disable systemd-timesyncd 2>/dev/null || true
        fi
    fi

    # 配置 Chrony - 使用全球可达的 NTP 服务器
    local chrony_conf="/etc/chrony/chrony.conf"
    if [[ "$PKG_MANAGER" == "dnf" ]] || [[ "$PKG_MANAGER" == "yum" ]]; then
        chrony_conf="/etc/chrony.conf"
    elif [[ "$PKG_MANAGER" == "apk" ]]; then
        chrony_conf="/etc/chrony/chrony.conf"
        mkdir -p /etc/chrony
    fi

    cat > "$chrony_conf" <<CHRONYCFG
server time.google.com iburst
server time.cloudflare.com iburst
server pool.ntp.org iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
CHRONYCFG

    # Alpine 需要确保 driftfile 目录存在
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        mkdir -p /var/lib/chrony
    fi

    # 启动并启用服务
    local svc_name
    svc_name=$(get_chrony_service_name)
    service_enable "$svc_name"

    if ! service_restart "$svc_name" 2>/dev/null; then
        timesync_handle_start_failure
        return
    fi

    # 强制同步一次
    sleep 1
    chronyc -a makestep >/dev/null 2>&1 || true

    # 写入硬件时钟 (容器中可能失败，忽略错误)
    hwclock --systohc 2>/dev/null || true

    log_info "$(msg timesync_installed)"
    echo ""
    echo -e "  $(msg timesync_current): ${GREEN}$(date -R)${NC}"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 处理 chrony 启动失败
timesync_handle_start_failure() {
    local svc_name
    svc_name=$(get_chrony_service_name)

    echo ""
    log_error "$(msg timesync_start_failed)"
    echo ""

    # 检查是否是容器环境导致的 adjtimex 错误
    local journal_err=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        journal_err=$(journalctl -u "$svc_name" --no-pager -n 10 2>/dev/null || true)
    fi

    if echo "$journal_err" | grep -q "adjtimex.*not permitted\|Operation not permitted" 2>/dev/null; then
        show_container_timesync_hint
    else
        echo -e "  ${BLUE}$(msg timesync_check_log):${NC}"
        echo ""
        if [[ -n "$journal_err" ]]; then
            echo "$journal_err" | tail -5 | while IFS= read -r line; do
                echo "    $line"
            done
        fi
        echo ""
    fi

    read -rp "$(msg menu_press_enter)"
}

# 通过 HTTP 头检查时间准确度 (无需任何特权，适用于容器环境)
timesync_check() {
    echo ""
    log_info "$(msg timesync_checking)"
    echo ""

    local remote_epoch="" local_epoch="" offset=""
    local sources=("https://www.google.com" "https://www.cloudflare.com" "https://www.apple.com")
    local src_used=""

    for src in "${sources[@]}"; do
        local http_date
        http_date=$(curl -sI --max-time 5 --proto '=https' "$src" 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: *//' | tr -d '\r')
        if [[ -n "$http_date" ]]; then
            remote_epoch=$(date -d "$http_date" +%s 2>/dev/null)
            if [[ -n "$remote_epoch" ]]; then
                src_used="$src"
                break
            fi
        fi
    done

    if [[ -z "$remote_epoch" ]]; then
        log_error "$(msg timesync_offset_fail)"
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    local_epoch=$(date +%s)
    offset=$(( local_epoch - remote_epoch ))
    # 取绝对值
    local abs_offset=${offset#-}

    echo -e "  $(msg timesync_current): ${YELLOW}$(date -R)${NC}"
    echo -e "  Remote (${src_used}): ${YELLOW}$(date -d "@$remote_epoch" -R 2>/dev/null)${NC}"
    echo ""
    echo -e "  $(msg timesync_offset): ${CYAN}${offset}${NC} $(msg timesync_seconds)"
    echo ""

    if [[ "$abs_offset" -le 30 ]]; then
        echo -e "  ${GREEN}✓${NC} $(msg timesync_offset_ok)"
    elif [[ "$abs_offset" -le 90 ]]; then
        echo -e "  ${YELLOW}⚠${NC} $(msg timesync_offset_warn)"
        echo -e "  ${YELLOW}    (SS2022 tolerance: ~30s)${NC}"
    else
        echo -e "  ${RED}✗${NC} $(msg timesync_offset_warn)"
        echo -e "  ${RED}    (SS2022 tolerance: ~30s, current: ${abs_offset}s)${NC}"
        echo ""
        if is_container_env && ! check_time_capability; then
            echo -e "  ${YELLOW}$(msg timesync_container_no_host)${NC}"
            echo -e "  $(msg timesync_container_detail)"
        fi
    fi

    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 强制同步时间
timesync_force() {
    echo ""
    if ! is_timesync_installed; then
        log_error "$(msg timesync_not_installed)"
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    log_info "$(msg timesync_forcing)"

    local svc_name
    svc_name=$(get_chrony_service_name)

    # 确保服务在运行
    if ! service_is_active "$svc_name" 2>/dev/null; then
        if ! service_start "$svc_name" 2>/dev/null; then
            timesync_handle_start_failure
            return
        fi
        sleep 1
    fi

    # 强制步进同步
    chronyc -a makestep 2>/dev/null

    # 写入硬件时钟
    hwclock --systohc 2>/dev/null || true

    log_info "$(msg timesync_forced)"
    echo ""
    echo -e "  $(msg timesync_current): ${GREEN}$(date -R)${NC}"
    echo ""

    # 显示 chronyc tracking 信息
    if command -v chronyc &>/dev/null; then
        echo -e "  ${BLUE}Chrony Tracking:${NC}"
        chronyc tracking 2>/dev/null | while IFS= read -r line; do
            echo "    $line"
        done
    fi

    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 卸载时间同步
timesync_uninstall() {
    echo ""
    if ! is_timesync_installed; then
        log_error "$(msg timesync_not_installed)"
        echo ""
        read -rp "$(msg menu_press_enter)"
        return
    fi

    log_info "$(msg timesync_removing)"

    local svc_name
    svc_name=$(get_chrony_service_name)

    service_stop "$svc_name"
    service_disable "$svc_name"

    case "$PKG_MANAGER" in
        apt)
            apt-get remove -y chrony >/dev/null 2>&1
            ;;
        dnf)
            dnf remove -y chrony >/dev/null 2>&1
            ;;
        yum)
            yum remove -y chrony >/dev/null 2>&1
            ;;
        apk)
            apk del chrony >/dev/null 2>&1
            ;;
    esac

    log_info "$(msg timesync_removed)"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 时间同步菜单
cmd_timesync() {
    while true; do
        clear
        local sync_status sync_display svc_name

        sync_status=$(get_timesync_status)
        case "$sync_status" in
            running)
                sync_display="${GREEN}$(msg timesync_synced)${NC}"
                ;;
            stopped)
                sync_display="${YELLOW}Stopped${NC}"
                ;;
            *)
                sync_display="${RED}$(msg timesync_not_installed)${NC}"
                ;;
        esac

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg timesync_title)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg timesync_status): $sync_display"
        echo -e "  $(msg timesync_current): ${YELLOW}$(date -R)${NC}"
        echo -e "  $(msg timesync_timezone): ${YELLOW}$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo 'N/A')${NC}"

        # 显示容器类型提示
        if is_container_env; then
            local virt
            virt=$(detect_virt_type)
            echo -e "  $(msg timesync_env): ${YELLOW}${virt}${NC}"
        fi
        echo ""

        # 如果 chrony 已安装并运行，显示源信息
        if [[ "$sync_status" == "running" ]] && command -v chronyc &>/dev/null; then
            echo -e "  ${BLUE}NTP Sources:${NC}"
            chronyc sources 2>/dev/null | tail -n +3 | while IFS= read -r line; do
                echo "    $line"
            done
            echo ""
        fi

        echo -e "  ${GREEN}1.${NC} $(msg timesync_install)"
        echo -e "  ${GREEN}2.${NC} $(msg timesync_force)"
        echo -e "  ${GREEN}3.${NC} $(msg timesync_check)"
        echo -e "  ${GREEN}4.${NC} $(msg timesync_uninstall)"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-4]: "
        read -r choice

        case "$choice" in
            1) timesync_install ;;
            2) timesync_force ;;
            3) timesync_check ;;
            4) timesync_uninstall ;;
            0) return ;;
            *) ;;
        esac
    done
}

# SS2022 安装后自动提示时间同步
prompt_timesync_for_ss2022() {
    # 已安装且运行中则跳过
    if is_timesync_installed; then
        local svc_name
        svc_name=$(get_chrony_service_name)
        if service_is_active "$svc_name" 2>/dev/null; then
            return
        fi
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}⚠${NC}  $(msg timesync_ss2022_hint)"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 容器环境且无权限: 只允许校验或跳过，绝不尝试修改宿主机时钟。
    if is_container_env && ! check_time_capability; then
        echo -e "  $(msg timesync_container_no_host)"
        echo -e "  ${GREEN}1.${NC} $(msg timesync_check)"
        echo -e "  ${RED}0.${NC} $(msg timesync_skip)"
        echo ""
        echo -n "  $(msg menu_choice) [0-1]: "
        local answer
        read -r answer
        if [[ "$answer" == "1" ]]; then
            timesync_check
        fi
        return 0
    fi

    echo -e "  ${GREEN}1.${NC} $(msg timesync_install)"
    echo -e "  ${GREEN}2.${NC} $(msg timesync_check)"
    echo -e "  ${RED}0.${NC} $(msg timesync_skip)"
    echo ""
    echo -n "  $(msg menu_choice) [0-2]: "
    local answer
    read -r answer
    case "$answer" in
        1) timesync_install ;;
        2) timesync_check ;;
        *) return 0 ;;
    esac
}

# ============== 协议 / 内核升级向导 ==============
#
# 用旧版本脚本装过节点的机器，升级脚本之后节点文件和运行中的内核仍然是旧的：普通
# 安装从不替换健康的既有内核，也不会回头改已有节点。这里提供一条显式的迁移路径。
#
# 整个流程分三步，对应三组函数：
#   upgrade_scan     离线扫描（不联网、不改任何东西），列出可升级项；
#   upgrade_apply    执行选中的项，节点改动先快照、失败整体回滚；
#   cmd_upgrade      向导界面与 CLI 入口。
#
# 每个可升级项属于三类之一，界面按类别分组，默认勾选也按类别决定：
#   safe    只动服务端，客户端零改动 —— 推荐，默认勾选；
#   relink  会改变分享链接，客户端必须重新导入 —— 可选，默认不勾选；
#   info    只是告知，没有可执行的动作。
#
# 项的 ID 是稳定标识：core.xray / core.singbox / cfg.reality-fields /
# svc.hardening / geodata.cron / sysctl.template / links.pin，以及
# node.<节点名>.<sni|port443|shortid|split|vlessenc|hy2obfs|ss>。
UPGRADE_STATE_FILE="/root/.proxy_hub_upgrade"
UPGRADE_BACKUP_ROOT="/var/lib/proxy-hub/upgrade-backups"
declare -ga UPG_IDS=() UPG_CLASS=() UPG_TITLE=() UPG_NOTE=() UPG_COST=() UPG_SEL=()

# Usage: upgrade_add ID CLASS TITLE NOTE COST
upgrade_add() {
    UPG_IDS+=("$1")
    UPG_CLASS+=("$2")
    UPG_TITLE+=("$3")
    UPG_NOTE+=("$4")
    UPG_COST+=("$5")
    # 默认勾选：只有"客户端零改动"的推荐项。
    if [[ "$2" == "safe" ]]; then UPG_SEL+=(1); else UPG_SEL+=(0); fi
}

upgrade_has() {
    local id
    for id in ${UPG_IDS[@]+"${UPG_IDS[@]}"}; do
        [[ "$id" == "$1" ]] && return 0
    done
    return 1
}

# 节点的协议类型，含旧节点没有 PROTOCOL_TYPE 时按端口推断的兼容规则。
upgrade_node_protocol() {
    local file="$1" proto
    proto=$(safe_read_config_value "$file" "PROTOCOL_TYPE")
    if [[ -z "$proto" ]]; then
        if [[ -n "$(safe_read_config_value "$file" "PORT")" && -n "$(safe_read_config_value "$file" "XHTTP_PORT")" ]]; then
            proto="both"
        elif [[ -n "$(safe_read_config_value "$file" "XHTTP_PORT")" ]]; then
            proto="xhttp"
        else
            proto="vision"
        fi
    fi
    printf '%s' "$proto"
}

# 离线扫描，结果写入 UPG_* 数组。不联网、不修改任何文件或服务。
upgrade_scan() {
    UPG_IDS=() UPG_CLASS=() UPG_TITLE=() UPG_NOTE=() UPG_COST=() UPG_SEL=()
    local name installed baseline

    # ---- 内核低于安全基线 ----
    while read -r name installed baseline; do
        case "$name" in
            xray)
                upgrade_add core.xray safe \
                    "$(t2 "更新 Xray：v$installed → 最新稳定版" "Update Xray: v$installed → latest stable")" \
                    "$(t2 "当前版本低于安全基线 v$baseline：之后的版本默认关闭 MPTCP（规避 Linux 内核漏洞）并移除了有问题的根证书。" \
                        "Below the security baseline v$baseline: later releases turn MPTCP off by default (a Linux kernel flaw) and drop compromised root certificates.")" \
                    "$(t2 "自动校验官方 SHA-256，先用新版本检查现有配置，启动失败自动回滚。服务会重启一次（几秒）。" \
                        "Verifies the official SHA-256, checks the current config with the new version, and rolls back if it fails to start. One restart of a few seconds.")"
                ;;
            sing-box)
                upgrade_add core.singbox safe \
                    "$(t2 "更新 sing-box：v$installed → 最新稳定版" "Update sing-box: v$installed → latest stable")" \
                    "$(t2 "当前版本低于安全基线 v$baseline：之后的版本里 AnyTLS 默认不再上传客户端信息。" \
                        "Below the security baseline v$baseline: later releases stop AnyTLS from uploading client metadata by default.")" \
                    "$(t2 "自动校验官方 SHA-256，先用新版本检查现有配置，启动失败自动回滚。服务会重启一次（几秒）。" \
                        "Verifies the official SHA-256, checks the current config with the new version, and rolls back if it fails to start. One restart of a few seconds.")"
                ;;
        esac
    done < <(core_baseline_gaps)

    # ---- Xray 配置仍在用旧字段 ----
    if [[ -s "$XRAY_CONF" ]] && jq -e '[.inbounds[]?.streamSettings.realitySettings // empty
            | select(has("dest") or has("fingerprint"))] | length > 0' "$XRAY_CONF" >/dev/null 2>&1; then
        if xray_supports target || upgrade_has core.xray; then
            upgrade_add cfg.reality-fields safe \
                "$(t2 "重新生成 Xray 配置（改用新版字段写法）" "Regenerate the Xray config with current field names")" \
                "$(t2 "现有配置还在用旧字段 dest 和一个服务端无效的 fingerprint；新版核心以 target 为正式写法。" \
                    "The config still uses the legacy dest field and a fingerprint that servers ignore; current cores use target.")" \
                "$(t2 "只改服务端配置文件，节点参数与分享链接完全不变。Xray 会重启一次。" \
                    "Only the server config changes; node parameters and share links stay the same. Xray restarts once.")"
        fi
    fi

    # ---- 服务沙箱加固 ----
    if service_hardening_applicable; then
        local svc pending=""
        for svc in xray "$SINGBOX_SERVICE"; do
            if service_is_active "$svc" && ! service_hardening_is_applied "$svc" \
                && [[ ! -e "$(service_hardening_skip_marker "$svc")" ]]; then
                pending+="${pending:+ / }$svc"
            fi
        done
        if [[ -n "$pending" ]]; then
            upgrade_add svc.hardening safe \
                "$(t2 "为服务启用沙箱加固：$pending" "Enable sandbox hardening for: $pending")" \
                "$(t2 "代理内核以 root 运行却只需要网络权限；加固后即使内核出现漏洞，能造成的破坏也小得多。" \
                    "The cores run as root but only need the network; hardening limits what a compromised core could do.")" \
                "$(t2 "服务重启一次；如果在这台机器上加固后起不来，会自动撤销并恢复原状。" \
                    "One restart; if the service cannot start hardened on this machine, it is reverted automatically.")"
        fi
    fi

    # ---- GeoData 定时更新未校验 ----
    if geodata_cron_is_legacy; then
        upgrade_add geodata.cron safe \
            "$(t2 "把 GeoIP/GeoSite 的定时更新换成带校验的版本" "Switch the scheduled GeoIP/GeoSite update to the verified one")" \
            "$(t2 "现在的定时任务把下载结果直接覆盖到数据文件上，下载中断或被篡改都会让路由数据损坏。" \
                "The current job writes downloads straight over the live files, so an interrupted or tampered download corrupts routing data.")" \
            "$(t2 "只替换定时任务；现有数据文件不动，下次更新开始校验 SHA-256。" \
                "Only the cron job changes; existing data is untouched and the next update verifies SHA-256.")"
    fi

    # ---- sysctl 调优模板过时 ----
    if sysctl_tuning_is_legacy; then
        upgrade_add sysctl.template safe \
            "$(t2 "刷新网络调优参数" "Refresh the network tuning parameters")" \
            "$(t2 "现有调优文件含一个内核早已忽略的参数，缓冲区上限也偏小。" \
                "The tuning file sets a key the kernel has long ignored and uses a low buffer ceiling.")" \
            "$(t2 "保留你当前的拥塞控制算法，立即生效，无需重启。" \
                "Keeps your current congestion control, takes effect immediately, no restart.")"
    fi

    # ---- 逐节点 ----
    local file node proto sni main_port port443_offered=0 pinned_nodes=""
    for file in "$NODES_DIR"/*.env; do
        [[ -f "$file" ]] || continue
        node=$(basename "$file" .env)
        proto=$(upgrade_node_protocol "$file")
        sni=$(safe_read_config_value "$file" "SNI")
        case "$proto" in
            vision|xhttp|both|anytls_reality)
                if reality_target_discouraged "$sni"; then
                    upgrade_add "node.$node.sni" relink \
                        "$(t2 "节点 $node：更换 REALITY 伪装域名（当前 $sni）" "Node $node: replace the REALITY target (now $sni)")" \
                        "$(t2 "Apple / iCloud 域名被太多节点借用，已成为被重点关照的特征，新版 Xray 也会对此告警。" \
                            "Apple / iCloud domains are borrowed by so many nodes that they draw attention; current Xray warns about them.")" \
                        "$(t2 "自动测速并选出新的域名，无需你填写。客户端需要重新导入这个节点的链接。" \
                            "A new domain is picked by the latency test for you. Clients must re-import this node's link.")"
                fi
                main_port=$(safe_read_config_value "$file" "PORT")
                [[ "$proto" == "xhttp" ]] && main_port=$(safe_read_config_value "$file" "XHTTP_PORT")
                if [[ -n "$main_port" && "$main_port" != "443" ]] && (( port443_offered == 0 )) \
                    && is_port_free 443 tcp && ! node_tcp_port_claimed 443; then
                    port443_offered=1
                    upgrade_add "node.$node.port443" relink \
                        "$(t2 "节点 $node：把端口从 $main_port 改到 443" "Node $node: move the port from $main_port to 443")" \
                        "$(t2 "REALITY 伪装成访问真实网站，而真实网站都在 443；用其他端口时伪装效果打折。" \
                            "REALITY poses as a visit to a real website, and real websites answer on 443; another port weakens the disguise.")" \
                        "$(t2 "需在云安全组放行 443/tcp。客户端需要重新导入这个节点的链接。" \
                            "Allow 443/tcp in the cloud firewall. Clients must re-import this node's link.")"
                fi
                if [[ "$proto" == "both" && -z "$(safe_read_config_value "$file" "XHTTP_PUBLIC_KEY")" ]]; then
                    upgrade_add "node.$node.split" relink \
                        "$(t2 "节点 $node：给 XHTTP 生成独立凭据" "Node $node: give XHTTP its own credentials")" \
                        "$(t2 "Vision 和 XHTTP 现在共用同一套 UUID 和密钥，其中一个暴露，另一个也跟着暴露。" \
                            "Vision and XHTTP share one UUID and key pair today, so exposing one exposes the other.")" \
                        "$(t2 "新凭据自动生成。只有 XHTTP 的链接会变，Vision 链接不受影响。" \
                            "New credentials are generated for you. Only the XHTTP link changes; the Vision link keeps working.")"
                fi
                local short_id
                short_id=$(safe_read_config_value "$file" "SHORT_ID")
                if [[ -n "$short_id" ]] && (( ${#short_id} < 16 )); then
                    upgrade_add "node.$node.shortid" relink \
                        "$(t2 "节点 $node：把 shortId 换成 16 位（当前 ${#short_id} 位）" "Node $node: replace the short ID with a 16-character one (now ${#short_id})")" \
                        "$(t2 "新装节点已使用满长度的 shortId。收益很有限：只是与新节点统一格式，不换也不影响安全性。" \
                            "New nodes use full-length short IDs. The gain is small: it only aligns the format, and keeping the old one is not a weakness.")" \
                        "$(t2 "新 shortId 随机生成。客户端需要重新导入这个节点的链接。" \
                            "The new short ID is random. Clients must re-import this node's link.")"
                fi
                if [[ "$proto" != "anytls_reality" && -z "$(safe_read_config_value "$file" "VLESS_DECRYPTION")" ]] \
                    && xray_supports vlessenc; then
                    upgrade_add "node.$node.vlessenc" relink \
                        "$(t2 "节点 $node：启用 VLESS Encryption（后量子加密）" "Node $node: enable VLESS Encryption (post-quantum)")" \
                        "$(t2 "防止今天被录下的流量将来被量子计算机解密。密钥自动生成。" \
                            "Keeps traffic recorded today from being decrypted by a future quantum computer. Keys are generated for you.")" \
                        "$(t2 "要求客户端内核为 Xray 25.9 或更新；旧客户端将无法连接。客户端需要重新导入链接。" \
                            "Requires a client core of Xray 25.9 or newer; older clients stop connecting. Clients must re-import the link.")"
                fi
                ;;
            hysteria2)
                if [[ -z "$(safe_read_config_value "$file" "HY2_DOMAIN")" ]]; then
                    pinned_nodes+="${pinned_nodes:+, }$node"
                    if [[ -z "$(safe_read_config_value "$file" "HY2_OBFS_PASSWORD")" ]]; then
                        upgrade_add "node.$node.hy2obfs" relink \
                            "$(t2 "节点 $node：启用 Salamander 混淆" "Node $node: enable Salamander obfuscation")" \
                            "$(t2 "Hysteria2 默认的握手特征很容易被识别；混淆后流量看不出协议。密码随机生成。" \
                                "Plain Hysteria2 is easy to recognise by its handshake; obfuscation hides the protocol. The password is random.")" \
                            "$(t2 "客户端需要重新导入这个节点的链接（混淆密码已包含在链接里）。" \
                                "Clients must re-import this node's link (the obfs password is included in it).")"
                    fi
                fi
                ;;
            shadowsocks)
                upgrade_add "node.$node.ss" info \
                    "$(t2 "节点 $node 使用 Shadowsocks" "Node $node uses Shadowsocks")" \
                    "$(t2 "Shadowsocks 没有流量伪装，新版 Xray 已对它给出弃用警告；建议只用于中转或落地，跨境直连改用 REALITY 系协议。" \
                        "Shadowsocks has no disguise and current Xray prints a deprecation warning for it; keep it for relay or landing hops.")" \
                    "$(t2 "无需操作，节点可继续使用。" "No action needed; the node keeps working.")"
                ;;
        esac
    done

    if [[ -n "$pinned_nodes" ]]; then
        upgrade_add links.pin info \
            "$(t2 "Hysteria2 分享链接已加入证书指纹：$pinned_nodes" "Hysteria2 share links now pin the certificate: $pinned_nodes")" \
            "$(t2 "Xray 内核的客户端自 2026-06-01 起不再接受只带 insecure 的自签名链接，新链接多了 pinSHA256。" \
                "Clients on an Xray core stopped accepting insecure-only links for self-signed nodes on 2026-06-01; new links add pinSHA256.")" \
            "$(t2 "服务端无需改动。客户端连不上时，在主菜单「查看节点信息」里重新复制链接即可。" \
                "Nothing changes on the server. If a client cannot connect, copy the link again from the node info view.")"
    fi
}

# 当前扫描结果的指纹：ID 集合排序后的 SHA-256。用于记住用户已经看过哪一批。
upgrade_findings_digest() {
    (( ${#UPG_IDS[@]} > 0 )) || return 0
    printf '%s\n' "${UPG_IDS[@]}" | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

# 记住"这一批已处理/已知悉"，之后只有出现新的项才再次提示。
upgrade_ack_save() {
    upgrade_scan
    upgrade_findings_digest >"$UPGRADE_STATE_FILE" 2>/dev/null || return 0
    chmod 600 "$UPGRADE_STATE_FILE" 2>/dev/null || true
}

# 是否存在用户还没看过的可升级项（会先执行一次扫描）。状态文件按不可信输入处理。
upgrade_pending() {
    local digest acked=""
    upgrade_scan
    (( ${#UPG_IDS[@]} > 0 )) || return 1
    digest=$(upgrade_findings_digest)
    if [[ -f "$UPGRADE_STATE_FILE" && ! -L "$UPGRADE_STATE_FILE" ]]; then
        read -r acked <"$UPGRADE_STATE_FILE" 2>/dev/null || acked=""
        acked="${acked//[^0-9a-f]/}"
    fi
    [[ "$digest" != "$acked" ]]
}

# 分组打印扫描结果。Usage: upgrade_print_findings [with_selection]
upgrade_print_findings() {
    local with_selection="${1:-}" class index number=0 box header shown
    for class in safe relink info; do
        shown=0
        for index in "${!UPG_IDS[@]}"; do
            [[ "${UPG_CLASS[$index]}" == "$class" ]] || continue
            if (( shown == 0 )); then
                case "$class" in
                    safe) header="${GREEN}$(t2 "推荐 · 客户端无需任何改动" "Recommended · nothing changes for clients")${NC}" ;;
                    relink) header="${YELLOW}$(t2 "可选 · 客户端需要重新导入链接" "Optional · clients must re-import the link")${NC}" ;;
                    *) header="${BLUE}$(t2 "提示 · 无需操作" "Notes · no action needed")${NC}" ;;
                esac
                echo ""
                echo -e "  $header"
                shown=1
            fi
            if [[ "$class" == "info" ]]; then
                echo -e "   ${BLUE}·${NC} ${UPG_TITLE[$index]}"
            else
                number=$((number + 1))
                box=""
                if [[ -n "$with_selection" ]]; then
                    if [[ "${UPG_SEL[$index]}" == 1 ]]; then box="${GREEN}[x]${NC} "; else box="[ ] "; fi
                fi
                echo -e "   ${box}${GREEN}${number}.${NC} ${UPG_TITLE[$index]}"
            fi
            menu_note "${UPG_NOTE[$index]}" "${UPG_COST[$index]}"
        done
    done
}

# 第 N 个可选择项（safe / relink，按显示顺序编号）对应的数组下标。
upgrade_index_of_number() {
    local want="$1" class index number=0
    for class in safe relink; do
        for index in "${!UPG_IDS[@]}"; do
            [[ "${UPG_CLASS[$index]}" == "$class" ]] || continue
            number=$((number + 1))
            if (( number == want )); then
                printf '%s' "$index"
                return 0
            fi
        done
    done
    return 1
}

# 只读列出可升级项（CLI: upgrade check）。
cmd_upgrade_check() {
    upgrade_scan
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        $(t2 "协议 / 内核升级检查" "Protocol / core upgrade check")${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    if (( ${#UPG_IDS[@]} == 0 )); then
        echo ""
        echo -e "  ${GREEN}$(t2 "没有可升级项：节点与内核都已是当前写法。" "Nothing to upgrade: nodes and cores are current.")${NC}"
        echo ""
        return 0
    fi
    upgrade_print_findings
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "  $(t2 "进入升级向导" "Open the upgrade wizard"): ${YELLOW}bash $0 upgrade${NC}"
    echo ""
}

# ---- 执行 ----

declare -ga UPG_DONE=() UPG_FAILED=() UPG_RELINK_NODES=()

# 快照节点文件与两个内核的配置，输出快照目录。节点改动失败时据此整体回滚；成功后
# 也保留最近 5 份，万一新链接在客户端上有问题，还能手工找回旧参数。
upgrade_snapshot() {
    local dir stale file
    dir="$UPGRADE_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p -- "$dir/nodes" || return 1
    chmod 700 -- "$UPGRADE_BACKUP_ROOT" "$dir" || return 1
    for file in "$NODES_DIR"/*.env; do
        [[ -f "$file" ]] || continue
        cp -p -- "$file" "$dir/nodes/" || return 1
    done
    [[ -f "$XRAY_CONF" ]] && { cp -p -- "$XRAY_CONF" "$dir/xray-config.json" || return 1; }
    [[ -f "$SINGBOX_CONF" ]] && { cp -p -- "$SINGBOX_CONF" "$dir/sing-box-config.json" || return 1; }
    while IFS= read -r stale; do
        [[ -n "$stale" && "$stale" == "$UPGRADE_BACKUP_ROOT"/* ]] && rm -rf -- "$stale"
    done < <(ls -1dt -- "$UPGRADE_BACKUP_ROOT"/*/ 2>/dev/null | tail -n +6)
    printf '%s\n' "$dir"
}

# 把节点文件恢复成快照里的内容。升级不增删节点，只需按文件覆盖回去。
upgrade_restore() {
    local dir="$1" file
    [[ -d "$dir/nodes" ]] || return 1
    for file in "$dir"/nodes/*.env; do
        [[ -f "$file" ]] || continue
        cp -p -- "$file" "$NODES_DIR/" || return 1
    done
}

# 自动测速并挑出一个新的 REALITY 目标（按延迟 + ASN/CDN 评分），输出域名。
upgrade_pick_sni() {
    local -A upg_latency=()
    local -a upg_domains=() upg_latencies=()
    test_domains_parallel upg_latency >/dev/null 2>&1 || true
    (( ${#upg_latency[@]} > 0 )) || return 1
    rank_sni_candidates upg_latency upg_domains upg_latencies
    [[ -n "${upg_domains[0]:-}" ]] || return 1
    printf '%s' "${upg_domains[0]}"
}

# 对一个节点执行一种升级并写回节点文件（不重建配置，由调用方统一重建）。
# Usage: upgrade_apply_node NODE KIND
upgrade_apply_node() {
    local node="$1" kind="$2" proto new_sni
    CURRENT_NODE_NAME="$node"
    load_node_for_edit || return 1
    # 很旧的节点文件没有 PROTOCOL_TYPE。save_env 会把缺失值写成 vision，那样一个靠
    # 端口推断出来的 both / xhttp 节点会在重存时被改成 vision，所以先把类型定下来。
    proto=$(upgrade_node_protocol "$(get_node_file "$node")")
    PROTOCOL_TYPE="$proto"

    case "$kind" in
        sni)
            new_sni=$(upgrade_pick_sni) || return 1
            reality_target_discouraged "$new_sni" && return 1
            SNI="$new_sni"
            ;;
        port443)
            is_port_free 443 tcp && ! node_tcp_port_claimed 443 || return 1
            if [[ "$proto" == "xhttp" ]]; then XHTTP_PORT=443; else PORT=443; fi
            ;;
        split)
            [[ "$proto" == "both" ]] || return 1
            gen_xhttp_credentials >/dev/null 2>&1 || return 1
            ;;
        vlessenc)
            xray_supports vlessenc || return 1
            gen_vlessenc_keys x25519 || return 1
            ;;
        hy2obfs)
            HY2_OBFS_PASSWORD=$(openssl rand -hex 16) || return 1
            ;;
        shortid)
            SHORT_ID=$(openssl rand -hex 8) || return 1
            # 已拆分凭据的 both 节点，XHTTP 那一个同样换成满长度。
            [[ -n "$XHTTP_SHORT_ID" ]] && (( ${#XHTTP_SHORT_ID} < 16 )) && XHTTP_SHORT_ID=$(openssl rand -hex 8)
            ;;
        *) return 1 ;;
    esac
    save_env
}

upgrade_mark_done() { UPG_DONE+=("$1"); }
upgrade_mark_failed() { UPG_FAILED+=("$1"); }

# 执行选中的升级项。结果写入 UPG_DONE / UPG_FAILED / UPG_RELINK_NODES；有任何一项
# 失败时返回非零，但一项失败不会中断其余无关的项。
#
# 顺序固定为：内核 → 节点与配置 → 系统项。先更新内核，后面的配置才能用上新字段；
# 所有节点改动合并成一次配置重建，重建或重启失败时用快照整体恢复节点文件并再次
# 重建，保证不会留下"节点文件是新的、运行中的配置是旧的"这种半完成状态。
# Usage: upgrade_apply ID...
upgrade_apply() {
    local id node kind snapshot="" need_regen=0 regen_requested=0 svc rc
    local -a node_ids=() applied_ids=()
    UPG_DONE=() UPG_FAILED=() UPG_RELINK_NODES=()
    (( $# > 0 )) || return 0

    # ---- 1. 内核 ----
    for id in "$@"; do
        case "$id" in
            core.xray)
                log_info "$(t2 "正在更新 Xray..." "Updating Xray...")"
                if XRAY_CHANNEL=stable cmd_xray_update; then upgrade_mark_done "$id"; else upgrade_mark_failed "$id"; fi
                XRAY_CAPS=""
                ;;
            core.singbox)
                log_info "$(t2 "正在更新 sing-box..." "Updating sing-box...")"
                if singbox_install_release update; then upgrade_mark_done "$id"; else upgrade_mark_failed "$id"; fi
                ;;
            node.*) node_ids+=("$id") ;;
            cfg.reality-fields) regen_requested=1 ;;
        esac
    done

    # ---- 2. 节点与配置 ----
    if (( ${#node_ids[@]} > 0 || regen_requested == 1 )); then
        if ! snapshot=$(upgrade_snapshot); then
            log_error "$(t2 "无法创建升级前快照，已跳过所有节点改动" "Could not snapshot the nodes; node changes were skipped")"
            for id in ${node_ids[@]+"${node_ids[@]}"}; do upgrade_mark_failed "$id"; done
            (( regen_requested == 1 )) && upgrade_mark_failed cfg.reality-fields
        else
            log_info "$(t2 "升级前快照" "Pre-upgrade snapshot"): $snapshot"
            need_regen=$regen_requested
            for id in ${node_ids[@]+"${node_ids[@]}"}; do
                node="${id#node.}"
                kind="${node##*.}"
                node="${node%.*}"
                if upgrade_apply_node "$node" "$kind"; then
                    applied_ids+=("$id")
                    need_regen=1
                else
                    upgrade_mark_failed "$id"
                fi
            done
            if (( need_regen == 1 )); then
                if cmd_regenerate; then
                    for id in ${applied_ids[@]+"${applied_ids[@]}"}; do
                        upgrade_mark_done "$id"
                        node="${id#node.}"
                        node="${node%.*}"
                        [[ " ${UPG_RELINK_NODES[*]:-} " == *" $node "* ]] || UPG_RELINK_NODES+=("$node")
                        if [[ "$id" == *.port443 ]]; then
                            CURRENT_NODE_NAME="$node"
                            load_node_for_edit && open_node_firewall_ports "$(upgrade_node_protocol "$(get_node_file "$node")")"
                        fi
                    done
                    if (( regen_requested == 1 )); then
                        if jq -e '[.inbounds[]?.streamSettings.realitySettings // empty
                                | select(has("dest") or has("fingerprint"))] | length == 0' "$XRAY_CONF" >/dev/null 2>&1; then
                            upgrade_mark_done cfg.reality-fields
                        else
                            upgrade_mark_failed cfg.reality-fields
                        fi
                    fi
                else
                    log_error "$(t2 "新配置未能生效，正在恢复升级前的节点" "The new configuration did not come up; restoring the nodes as they were")"
                    if upgrade_restore "$snapshot" && cmd_regenerate; then
                        log_warn "$(t2 "已恢复到升级前状态，节点与分享链接均未改变" "Restored: nodes and share links are unchanged")"
                    else
                        log_error "$(t2 "自动恢复失败，请从快照手工恢复" "Automatic restore failed; recover manually from the snapshot"): $snapshot"
                    fi
                    for id in ${applied_ids[@]+"${applied_ids[@]}"}; do upgrade_mark_failed "$id"; done
                    (( regen_requested == 1 )) && upgrade_mark_failed cfg.reality-fields
                fi
            fi
        fi
    fi

    # ---- 3. 系统项 ----
    for id in "$@"; do
        case "$id" in
            svc.hardening)
                local hardened=0 reverted=0
                for svc in xray "$SINGBOX_SERVICE"; do
                    rc=0
                    service_hardening_ensure "$svc" force || rc=$?
                    (( rc == 0 )) && hardened=1
                    (( rc == 2 )) && reverted=1
                done
                if (( hardened == 1 && reverted == 0 )); then upgrade_mark_done "$id"; else upgrade_mark_failed "$id"; fi
                ;;
            geodata.cron)
                if install_geodata_helper && setup_geodata_cron && ! geodata_cron_is_legacy; then
                    upgrade_mark_done "$id"
                else
                    upgrade_mark_failed "$id"
                fi
                ;;
            sysctl.template)
                if sysctl_tuning_apply; then upgrade_mark_done "$id"; else upgrade_mark_failed "$id"; fi
                ;;
        esac
    done

    (( ${#UPG_FAILED[@]} == 0 ))
}

# 某个 ID 在最近一次扫描里的标题（找不到时回退为 ID 本身）。
upgrade_title_of() {
    local index
    for index in "${!UPG_IDS[@]}"; do
        if [[ "${UPG_IDS[$index]}" == "$1" ]]; then
            printf '%s' "${UPG_TITLE[$index]}"
            return 0
        fi
    done
    printf '%s' "$1"
}

# 打印执行结果；改过链接的节点逐个给出新的节点信息与分享链接。
upgrade_print_result() {
    local id node
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        $(t2 "升级结果" "Upgrade result")${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    for id in ${UPG_DONE[@]+"${UPG_DONE[@]}"}; do
        echo -e "  ${GREEN}✓${NC} $(upgrade_title_of "$id")"
    done
    for id in ${UPG_FAILED[@]+"${UPG_FAILED[@]}"}; do
        echo -e "  ${RED}✗${NC} $(upgrade_title_of "$id")  ${GRAY}($(t2 "未生效，原状态已保留" "not applied; the previous state was kept"))${NC}"
    done
    if (( ${#UPG_RELINK_NODES[@]} > 0 )); then
        echo ""
        echo -e "  ${YELLOW}$(t2 "以下节点的分享链接已改变，请在客户端删除旧节点并重新导入：" \
            "The share links of these nodes changed. Remove the old entry in your client and import again:")${NC}"
        for node in "${UPG_RELINK_NODES[@]}"; do
            CURRENT_NODE_NAME="$node"
            show_info
        done
    fi
    echo ""
}

# 非交互执行（CLI: upgrade apply recommended|all|ID,ID...）。
cmd_upgrade_apply() {
    local spec="${1:-recommended}" index id found rc=0
    local -a wanted=() selected=()
    if ! is_root; then
        log_error "$(msg run_as_root)"
        return 1
    fi
    upgrade_scan
    case "$spec" in
        recommended|safe)
            for index in "${!UPG_IDS[@]}"; do
                [[ "${UPG_CLASS[$index]}" == "safe" ]] && selected+=("${UPG_IDS[$index]}")
            done
            ;;
        all)
            for index in "${!UPG_IDS[@]}"; do
                [[ "${UPG_CLASS[$index]}" != "info" ]] && selected+=("${UPG_IDS[$index]}")
            done
            ;;
        *)
            IFS=',' read -r -a wanted <<<"$spec"
            for id in "${wanted[@]}"; do
                found=0
                for index in "${!UPG_IDS[@]}"; do
                    if [[ "${UPG_IDS[$index]}" == "$id" && "${UPG_CLASS[$index]}" != "info" ]]; then
                        selected+=("$id")
                        found=1
                    fi
                done
                if (( found == 0 )); then
                    log_error "$(t2 "不是当前可执行的升级项" "Not an applicable upgrade item"): $id"
                    return 1
                fi
            done
            ;;
    esac
    if (( ${#selected[@]} == 0 )); then
        log_info "$(t2 "没有需要执行的升级项" "Nothing to apply")"
        return 0
    fi
    upgrade_apply "${selected[@]}" || rc=$?
    upgrade_print_result
    upgrade_ack_save
    return "$rc"
}

# ---- 向导界面 ----

# 交互式升级向导。界面只做三件事：把每一项讲清楚、让用户勾选、确认后执行。
# 默认状态下直接回车就是"执行全部推荐项"，这些项都不需要动客户端；会改变分享链接
# 的项必须由用户主动勾选，并在执行前再确认一次。
cmd_upgrade_wizard() {
    local answer="" token index selected_count relink_selected rc=0
    local -a selected=() relink_titles=()
    if ! is_root; then
        log_error "$(msg run_as_root)"
        return 1
    fi
    upgrade_scan
    if (( ${#UPG_IDS[@]} == 0 )) || ! tty_available; then
        # 没有可升级项，或没有终端可以提问：退化为只读报告。
        cmd_upgrade_check
        if (( ${#UPG_IDS[@]} > 0 )); then
            echo -e "  $(t2 "无人值守执行推荐项" "Apply the recommended items unattended"): ${YELLOW}bash $0 upgrade apply recommended${NC}"
            echo ""
        fi
        return 0
    fi

    while true; do
        selected_count=0
        for index in "${!UPG_IDS[@]}"; do
            [[ "${UPG_SEL[$index]}" == 1 ]] && selected_count=$((selected_count + 1))
        done
        {
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}        $(t2 "协议 / 内核升级向导" "Protocol / core upgrade wizard")${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        menu_note "$(t2 "这台机器上有用旧版脚本创建的节点或旧版内核。下面逐项说明可以升级什么、为什么、有什么代价。" \
            "This server has nodes or cores created by an older script. Each item below says what can be upgraded, why, and what it costs.")" \
            "$(t2 "[x] 表示已勾选。直接回车会执行已勾选的项；在你确认之前不会改动任何东西。" \
            "[x] means selected. Enter applies the selected items; nothing changes until you confirm.")" \
            "$(t2 "节点改动会先做快照，新配置起不来时自动恢复原样。" \
            "Node changes are snapshotted first and restored automatically if the new configuration fails to start.")"
        upgrade_print_findings with_selection
        echo ""
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}$(t2 "回车" "Enter")${NC}  $(t2 "执行已勾选的 $selected_count 项" "apply the $selected_count selected item(s)")"
        echo -e "  ${GREEN}$(t2 "数字" "number")${NC}  $(t2 "切换勾选，可一次输入多个，如 2 5" "toggle an item; several at once, e.g. 2 5")"
        echo -e "  ${GREEN}r${NC}     $(t2 "只勾选推荐项（默认）" "select only the recommended items (default)")"
        echo -e "  ${GREEN}a${NC}     $(t2 "全部勾选（含需要重新导入链接的项）" "select everything, including items that change links")"
        echo -e "  ${GREEN}n${NC}     $(t2 "全部取消" "clear the selection")"
        echo -e "  ${GREEN}q${NC}     $(t2 "退出，不做任何改动" "quit without changing anything")"
        echo ""
        echo -n "  > "
        } | tty_print
        tty_read answer

        case "$answer" in
            q|Q|0)
                log_info "$(t2 "已退出，未做任何改动" "Left the wizard; nothing was changed")"
                return 0
                ;;
            r|R)
                for index in "${!UPG_IDS[@]}"; do
                    if [[ "${UPG_CLASS[$index]}" == "safe" ]]; then UPG_SEL[$index]=1; else UPG_SEL[$index]=0; fi
                done
                continue
                ;;
            a|A)
                for index in "${!UPG_IDS[@]}"; do
                    if [[ "${UPG_CLASS[$index]}" != "info" ]]; then UPG_SEL[$index]=1; fi
                done
                continue
                ;;
            n|N)
                for index in "${!UPG_IDS[@]}"; do UPG_SEL[$index]=0; done
                continue
                ;;
            "") ;;
            *)
                for token in ${answer//,/ }; do
                    if [[ "$token" =~ ^[0-9]{1,3}$ ]] && index=$(upgrade_index_of_number "$((10#$token))"); then
                        UPG_SEL[$index]=$(( 1 - UPG_SEL[index] ))
                    else
                        echo -e "  ${RED}$(t2 "无法识别的输入" "Unrecognised input"): $token${NC}" | tty_print
                    fi
                done
                continue
                ;;
        esac

        # ---- 回车：汇总并确认 ----
        selected=()
        relink_titles=()
        for index in "${!UPG_IDS[@]}"; do
            [[ "${UPG_SEL[$index]}" == 1 && "${UPG_CLASS[$index]}" != "info" ]] || continue
            selected+=("${UPG_IDS[$index]}")
            [[ "${UPG_CLASS[$index]}" == "relink" ]] && relink_titles+=("${UPG_TITLE[$index]}")
        done
        if (( ${#selected[@]} == 0 )); then
            {
            echo ""
            echo -e "  ${YELLOW}$(t2 "没有勾选任何项。" "Nothing is selected.")${NC}"
            echo -n "  $(t2 "以后不再提示这些项? [y/N]" "Stop reminding about these items? [y/N]"): "
            } | tty_print
            tty_read answer
            if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
                upgrade_ack_save
            fi
            return 0
        fi
        if (( ${#relink_titles[@]} > 0 )); then
            {
            echo ""
            echo -e "  ${YELLOW}$(t2 "注意：下面这些改动会让对应节点的旧分享链接失效，客户端必须重新导入：" \
                "Note: these changes invalidate the old share links; clients must import the new ones:")${NC}"
            for token in "${relink_titles[@]}"; do
                echo -e "   ${YELLOW}·${NC} $token"
            done
            menu_note "$(t2 "执行完成后会直接显示新的链接与二维码所需信息。" \
                "The new links are shown as soon as the upgrade finishes.")"
            echo -n "  $(t2 "确认执行? [y/N]" "Go ahead? [y/N]"): "
            } | tty_print
            tty_read answer
            if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
                continue
            fi
        fi
        break
    done

    upgrade_apply "${selected[@]}" || rc=$?
    upgrade_print_result
    upgrade_ack_save
    return "$rc"
}

# 打开交互菜单时调用：机器上有还没看过的可升级项，就先问一句。
# 提问只出现一次——选择"不再提示"或走完向导都会记下这一批；之后只有出现新的可升级
# 项（例如脚本更新带来新的安全基线）才会再问。任何时候都能从主菜单 P 进入向导。
upgrade_startup_prompt() {
    local answer="" index safe_count=0 relink_count=0 info_count=0
    is_root || return 0
    tty_available || return 0
    upgrade_pending || return 0
    for index in "${!UPG_IDS[@]}"; do
        case "${UPG_CLASS[$index]}" in
            safe) safe_count=$((safe_count + 1)) ;;
            relink) relink_count=$((relink_count + 1)) ;;
            *) info_count=$((info_count + 1)) ;;
        esac
    done
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        $(t2 "发现可以升级的协议 / 内核" "Protocol / core upgrades are available")${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    menu_note "$(t2 "这台机器上的节点或内核是旧版脚本创建的，新版脚本可以帮你升级：" \
        "The nodes or cores on this server were set up by an older script. This version can upgrade them:")"
    (( safe_count > 0 )) && echo -e "   ${GREEN}·${NC} $(t2 "$safe_count 项推荐升级（客户端无需任何改动）" "$safe_count recommended (nothing changes for clients)")"
    (( relink_count > 0 )) && echo -e "   ${YELLOW}·${NC} $(t2 "$relink_count 项可选升级（客户端需要重新导入链接）" "$relink_count optional (clients must re-import the link)")"
    (( info_count > 0 )) && echo -e "   ${BLUE}·${NC} $(t2 "$info_count 条提示" "$info_count note(s)")"
    echo ""
    echo -e "  ${GREEN}$(t2 "回车" "Enter")${NC}  $(t2 "查看详情并选择要升级的项（推荐）" "review the details and choose what to upgrade (recommended)")"
    echo -e "  ${GREEN}n${NC}     $(t2 "这次先不处理，下次打开再问" "not now; ask again next time")"
    echo -e "  ${GREEN}s${NC}     $(t2 "不再提示这些项（之后仍可从主菜单 P 进入）" "do not remind me about these (still reachable from the main menu, P)")"
    echo ""
    echo -n "  > "
    } | tty_print
    tty_read answer
    case "$answer" in
        n|N) return 0 ;;
        s|S) upgrade_ack_save ;;
        *) cmd_upgrade_wizard || true ;;
    esac
    return 0
}

# CLI 入口。Usage: cmd_upgrade [check | apply recommended|all|ID,ID...]
# 不带参数时进入向导。
cmd_upgrade() {
    case "${1:-}" in
        check|--check) cmd_upgrade_check ;;
        apply|--apply) cmd_upgrade_apply "${2:-recommended}" ;;
        *) cmd_upgrade_wizard ;;
    esac
}

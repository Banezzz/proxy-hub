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

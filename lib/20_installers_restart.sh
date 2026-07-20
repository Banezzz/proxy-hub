install_deps() {
    log_info "$(msg install_deps)"

    # 根据包管理器设置包名
    local required_packages
    case "$PKG_MANAGER" in
        apt)
            required_packages=(curl unzip tar openssl ca-certificates iproute2 qrencode jq cron)
            ;;
        dnf|yum)
            required_packages=(curl unzip tar openssl ca-certificates iproute qrencode jq cronie)
            ;;
        apk)
            # Alpine Linux 特殊包名
            # libqrencode-tools 提供 qrencode 命令
            required_packages=(curl unzip tar openssl ca-certificates iproute2 libqrencode-tools bash coreutils jq)
            ;;
        *)
            required_packages=(curl unzip tar openssl ca-certificates iproute qrencode jq)
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

install_xray() {
    # 检查 Xray 是否已安装
    if [[ -f "$XRAY_BIN" ]] && "$XRAY_BIN" version &>/dev/null; then
        log_info "Xray already installed, skipping..."
        return 0
    fi

    log_info "$(msg install_xray)"

    # Alpine Linux 需要手动安装（官方脚本依赖 systemd）
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        install_xray_alpine
    else
        # Security: Download script to temp file first, then execute
        # This allows for potential verification and avoids direct pipe-to-bash
        local installer_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        local tmp_installer="/tmp/xray-install-$$.sh"

        if ! secure_curl "$installer_url" -o "$tmp_installer"; then
            log_error "Failed to download Xray installer"
            rm -f "$tmp_installer"
            return 1
        fi

        # Execute downloaded script
        if ! bash "$tmp_installer" >/dev/null 2>&1; then
            log_error "Failed to install Xray. Please check your network connection."
            rm -f "$tmp_installer"
            return 1
        fi
        rm -f "$tmp_installer"
    fi
}

# Alpine Linux 专用 Xray 安装函数
install_xray_alpine() {
    local arch
    arch=$(uname -m)
    local xray_arch

    # 映射架构名称
    case "$arch" in
        x86_64)
            xray_arch="64"
            ;;
        aarch64|arm64)
            xray_arch="arm64-v8a"
            ;;
        armv7l)
            xray_arch="arm32-v7a"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    # 获取最新版本号（使用安全的 API 解析）
    local latest_version
    latest_version=$(fetch_github_release_tag "XTLS/Xray-core")
    if [[ -z "$latest_version" ]]; then
        log_error "Failed to get Xray latest version"
        return 1
    fi

    log_info "Installing Xray $latest_version for Alpine (${xray_arch})..."

    # 下载 Xray（使用安全的 curl 封装）
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${xray_arch}.zip"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! secure_curl "$download_url" -o "${tmp_dir}/xray.zip"; then
        log_error "Failed to download Xray"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 解压安装
    unzip -q "${tmp_dir}/xray.zip" -d "${tmp_dir}"
    mkdir -p /usr/local/bin /usr/local/etc/xray /usr/local/share/xray /var/log/xray

    install -m 755 "${tmp_dir}/xray" /usr/local/bin/xray
    [[ -f "${tmp_dir}/geoip.dat" ]] && install -m 644 "${tmp_dir}/geoip.dat" /usr/local/share/xray/
    [[ -f "${tmp_dir}/geosite.dat" ]] && install -m 644 "${tmp_dir}/geosite.dat" /usr/local/share/xray/

    rm -rf "$tmp_dir"

    # 创建 OpenRC 服务脚本
    create_xray_openrc_service

    log_info "Xray installed successfully on Alpine"
}

# 创建 Xray OpenRC 服务脚本
create_xray_openrc_service() {
    cat > /etc/init.d/xray <<'OPENRC_SERVICE'
#!/sbin/openrc-run

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

    chmod 755 /etc/init.d/xray
}

# ============== sing-box 安装（AnyTLS 支持） ==============

# 创建 sing-box systemd 服务
create_singbox_systemd_service() {
    cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service (AnyTLS)
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
description="sing-box service (AnyTLS)"

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
# AnyTLS 协议需要 sing-box >= 1.12.0
install_singbox() {
    if [[ -f "$SINGBOX_BIN" ]] && "$SINGBOX_BIN" version &>/dev/null; then
        log_info "sing-box already installed, skipping..."
        return 0
    fi

    log_info "Installing sing-box (required for AnyTLS)..."

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

# 通过 systemd timer + service 安装（Ubuntu/Debian/CentOS 等）
install_xray_restart_systemd() {
    local systemd_cal="$1"

    cat > "$XRAY_RESTART_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Restart proxy cores (proxy-hub)
After=xray.service sing-box.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for u in xray sing-box; do systemctl try-restart "\$u".service 2>/dev/null; done; true'
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

    if ! command -v crontab &>/dev/null; then
        log_warn "crontab not available; cannot schedule Xray restart"
        return 1
    fi

    # 重启所有在用的代理内核（Xray 和/或 sing-box），而不仅是 Xray
    local restart_cmd
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        restart_cmd="/bin/sh -c 'for s in xray sing-box; do [ -e /etc/init.d/\$s ] && rc-service \$s restart; done'"
    else
        restart_cmd="/bin/sh -c 'for u in xray sing-box; do systemctl try-restart \"\$u\".service 2>/dev/null; done'"
    fi

    local cron_line="$cron_expr $restart_cmd >/dev/null 2>&1 $XRAY_RESTART_CRON_MARKER"

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
            if [[ -z "$custom_cron" ]] || [[ $(echo "$custom_cron" | awk '{print NF}') -ne 5 ]]; then
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

# 协议类型: vision, xhttp, both, shadowsocks
PROTOCOL_TYPE="vision"
XHTTP_PORT=""
XHTTP_PATH=""

# Shadowsocks 相关变量
SS_METHOD=""
SS_PASSWORD=""

# AnyTLS 相关变量（协议类型: anytls, anytls_reality）
ANYTLS_PASSWORD=""
ANYTLS_PADDING_B64=""

# Shadowsocks 支持的加密方式
SS_METHODS_2022=(
    "2022-blake3-aes-256-gcm"
    "2022-blake3-chacha20-poly1305"
)
SS_METHODS_LEGACY=(
    "chacha20-ietf-poly1305"
    "aes-256-gcm"
)

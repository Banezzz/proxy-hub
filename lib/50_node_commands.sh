show_proxy_service_failure_logs() {
    local service_name="$1"
    local fallback_log="${2:-}"
    local output=""

    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        [[ -n "$fallback_log" ]] && output=$(tail -n 30 "$fallback_log" 2>/dev/null || true)
    else
        output=$(journalctl -u "$service_name" --no-pager -n 30 2>/dev/null || true)
    fi
    if [[ -n "$output" ]]; then
        printf '%s\n' "----- $service_name (last 30 lines) -----" >&2
        printf '%s\n' "$output" >&2
    fi
}

# Remove only the candidate node and prove that the previous core state can be
# rebuilt. A failed rollback remains a hard failure instead of being hidden.
rollback_candidate_node() {
    local protocol="$1"
    local node_name="$2"
    local node_file
    node_file=$(get_node_file "$node_name")

    rm -f "$node_file" 2>/dev/null
    rm -f "$SINGBOX_CERT_DIR/${node_name}.crt" "$SINGBOX_CERT_DIR/${node_name}.key" 2>/dev/null

    case "$protocol" in
        anytls|anytls_reality|hysteria2)
            if ! singbox_sync; then
                log_error "Rollback failed while restoring sing-box state"
                return 1
            fi
            ;;
        *)
            if ! write_config; then
                log_error "Rollback failed while rebuilding Xray config"
                return 1
            fi
            if [[ "$(xray_node_count)" -gt 0 ]]; then
                if ! service_restart xray || ! service_is_active xray; then
                    log_error "Rollback failed while restoring Xray service"
                    return 1
                fi
            else
                service_stop xray
            fi
            ;;
    esac
}

# Open only the transports used by a node. Firewall tooling is best-effort
# because cloud security groups and host policy may be managed externally, but
# every active-backend failure is surfaced to the operator.
open_node_firewall_ports() {
    local protocol="$1"

    case "$protocol" in
        hysteria2)
            open_firewall_port "$PORT" udp || \
                log_warn "Could not automatically open UDP port $PORT"
            ;;
        shadowsocks)
            open_firewall_port "$PORT" both || \
                log_warn "Could not automatically open TCP/UDP port $PORT"
            ;;
        anytls|anytls_reality|vision)
            if [[ -n "${PORT:-}" ]]; then
                open_firewall_port "$PORT" tcp || \
                    log_warn "Could not automatically open TCP port $PORT"
            fi
            ;;
        xhttp)
            if [[ -n "${XHTTP_PORT:-}" ]]; then
                open_firewall_port "$XHTTP_PORT" tcp || \
                    log_warn "Could not automatically open TCP port $XHTTP_PORT"
            fi
            ;;
        both)
            if [[ -n "${PORT:-}" ]]; then
                open_firewall_port "$PORT" tcp || \
                    log_warn "Could not automatically open TCP port $PORT"
            fi
            if [[ -n "${XHTTP_PORT:-}" ]]; then
                open_firewall_port "$XHTTP_PORT" tcp || \
                    log_warn "Could not automatically open TCP port $XHTTP_PORT"
            fi
            ;;
    esac

    return 0
}

cmd_install() {
    if ! is_root; then
        log_error "$(msg run_as_root)"
        return 1
    fi

    log_info "$(msg installing)"

    # 仅安装通用依赖（curl/tar/jq/qrencode/openssl 等）。
    # 代理内核（Xray 或 sing-box）在选择协议类型之后按需安装；
    # GeoIP/GeoSite 数据库不再默认下载，仅在启用 WARP 分流时才按需获取。
    install_deps

    # 交互式输入节点名称（或使用环境变量 name=xxx）
    if [[ -n "${name:-}" ]]; then
        CURRENT_NODE_NAME=$(printf '%s' "$name" | tr -cd 'a-zA-Z0-9_-')
        if [[ -z "$CURRENT_NODE_NAME" || "$CURRENT_NODE_NAME" != "$name" ]]; then
            log_error "Node name may contain only letters, numbers, underscore, and dash"
            return 1
        fi
        # 如果名称已存在，添加后缀
        local base_name="$CURRENT_NODE_NAME"
        local counter=1
        while node_exists "$CURRENT_NODE_NAME"; do
            CURRENT_NODE_NAME="${base_name}_${counter}"
            ((++counter))
        done
    else
        CURRENT_NODE_NAME=$(prompt_node_name)
    fi
    log_info "Node name: $CURRENT_NODE_NAME"

    # 选择协议类型（除非通过环境变量指定）
    if [[ -n "${proto:-}" ]]; then
        # 支持环境变量 proto=vision/xhttp/both/shadowsocks/ss/anytls/anytls-reality/hysteria2
        case "$proto" in
            xhttp) PROTOCOL_TYPE="xhttp" ;;
            both) PROTOCOL_TYPE="both" ;;
            shadowsocks|ss) PROTOCOL_TYPE="shadowsocks" ;;
            anytls) PROTOCOL_TYPE="anytls" ;;
            anytls-reality|anytls_reality|anytlsreality) PROTOCOL_TYPE="anytls_reality" ;;
            hysteria2|hy2) PROTOCOL_TYPE="hysteria2" ;;
            *) PROTOCOL_TYPE="vision" ;;
        esac
        log_info "协议类型: $PROTOCOL_TYPE"
    elif [[ -n "${xhttp:-}" ]]; then
        # 向后兼容: xhttp=true 等同于 proto=both
        if [[ "$xhttp" == "true" ]] || [[ "$xhttp" == "1" ]] || [[ "$xhttp" == "y" ]]; then
            PROTOCOL_TYPE="both"
            log_info "协议类型: both (Vision + XHTTP)"
        fi
    else
        prompt_protocol_type
    fi

    # 按所选协议安装对应内核：VLESS / Shadowsocks 用 Xray；AnyTLS / Hysteria2 用 sing-box。
    case "$PROTOCOL_TYPE" in
        anytls|anytls_reality|hysteria2)
            : # sing-box 在对应协议分支中安装
            ;;
        *)
            install_xray || { log_error "Xray 安装失败"; return 1; }
            ;;
    esac

    # Shadowsocks 和 VLESS 的安装流程不同
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        # Shadowsocks 安装流程
        # 选择加密方式（或使用环境变量 ssmethod=xxx）
        if [[ -n "${ssmethod:-}" ]]; then
            SS_METHOD="$ssmethod"
            log_info "加密方式: $SS_METHOD"
        else
            prompt_ss_method
        fi

        # 生成密码（或使用环境变量 sspwd=xxx）
        if [[ -n "${sspwd:-}" ]]; then
            SS_PASSWORD="$sspwd"
            log_info "使用指定密码"
        else
            gen_ss_password
        fi

        # 选择端口
        choose_ports

        # SS 不需要 SNI, UUID, Reality Keys
        SNI=""
        UUID=""
        PUBLIC_KEY=""
        PRIVATE_KEY=""
        SHORT_ID=""
        ANYTLS_PASSWORD=""
        ANYTLS_PADDING_B64=""
        HY2_PASSWORD=""
    elif [[ "$PROTOCOL_TYPE" == "hysteria2" ]]; then
        install_singbox || { log_error "sing-box 安装失败"; return 1; }
        gen_hy2_password || return 1
        SNI="${hy2sni:-www.bing.com}"
        if ! validate_tls_server_name "$SNI"; then
            log_error "Invalid Hysteria2 TLS SNI: $SNI"
            return 1
        fi
        choose_ports || return 1

        UUID=""
        PUBLIC_KEY=""
        PRIVATE_KEY=""
        SHORT_ID=""
        SS_METHOD=""
        SS_PASSWORD=""
        ANYTLS_PASSWORD=""
        ANYTLS_PADDING_B64=""
    elif [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "anytls_reality" ]]; then
        # AnyTLS 安装流程（基于 sing-box）
        install_singbox || { log_error "sing-box 安装失败"; return 1; }

        # SNI: REALITY 节点需要真实可达域名；plain 节点的 SNI 仅作伪装/证书 CN，
        # 但同样支持「测速选择 + 自定义」，与 REALITY 逻辑一致。
        if [[ -n "${reym:-}" ]]; then
            SNI="$reym"
            log_info "$(msg using_sni): $SNI"
        else
            rm -f "$CACHE_FILE" 2>/dev/null
            [[ "$PROTOCOL_TYPE" == "anytls" ]] && log_info "$(msg anytls_sni_note)"
            select_best_sni
        fi

        choose_ports

        # 生成密码与随机化 padding scheme
        gen_anytls_password
        ANYTLS_PADDING_B64="$(gen_anytls_padding | base64 -w0)"
        log_info "已生成随机化 AnyTLS padding scheme"

        if [[ "$PROTOCOL_TYPE" == "anytls_reality" ]]; then
            gen_reality_keys
        else
            UUID=""
            PUBLIC_KEY=""
            PRIVATE_KEY=""
            SHORT_ID=""
        fi
        HY2_PASSWORD=""
    else
        # VLESS 安装流程
        # 安装时清除 SNI 缓存，强制重新测试
        rm -f "$CACHE_FILE" 2>/dev/null

        if [[ -n "${reym:-}" ]]; then
            SNI="$reym"
            log_info "$(msg using_sni): $SNI"
        else
            select_best_sni
        fi

        gen_uuid
        choose_ports
        gen_reality_keys
        ANYTLS_PASSWORD=""
        ANYTLS_PADDING_B64=""
        HY2_PASSWORD=""
    fi

    # 检测双栈 IP
    detect_network_stack

    save_env

    if [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "anytls_reality" || "$PROTOCOL_TYPE" == "hysteria2" ]]; then
        # plain AnyTLS 与 Hysteria2 使用各节点独立的自签名证书。
        if [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "hysteria2" ]]; then
            if ! gen_selfsigned_cert "$CURRENT_NODE_NAME" "$SNI"; then
                log_error "Failed to generate TLS certificate, rolling back..."
                rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                    log_error "Manual recovery may be required for sing-box"
                return 1
            fi
        fi

        if ! singbox_sync; then
            log_error "Failed to configure or start sing-box, rolling back..."
            show_proxy_service_failure_logs "$SINGBOX_SERVICE" /var/log/sing-box.log
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for sing-box"
            return 1
        fi

        open_node_firewall_ports "$PROTOCOL_TYPE"
    else
        # 生成 Xray 配置文件，如果失败则回滚
        if ! write_config; then
            log_error "Failed to generate Xray config, rolling back..."
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for Xray"
            return 1
        fi

        service_enable xray
        if ! service_restart xray; then
            log_error "Xray service restart failed after install"
            show_proxy_service_failure_logs xray /var/log/xray/error.log
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for Xray"
            return 1
        fi

        sleep 1
        if ! service_is_active xray; then
            log_error "Xray service failed to become active after install"
            show_proxy_service_failure_logs xray /var/log/xray/error.log
            rollback_candidate_node "$PROTOCOL_TYPE" "$CURRENT_NODE_NAME" || \
                log_error "Manual recovery may be required for Xray"
            return 1
        fi

        open_node_firewall_ports "$PROTOCOL_TYPE"
    fi

    log_info "$(msg install_complete)"

    show_info

    show_node_qrcodes

    # 询问是否启用定时重启 Xray（仅首次创建节点时提示，或通过环境变量 restart= 指定）
    prompt_xray_restart_on_install

    # SS2022 安装完成后自动提示时间同步
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        prompt_timesync_for_ss2022
    fi
}

cmd_info() {
    select_node || return 1
    show_info
}

cmd_qr() {
    select_node || return 1

    if ! command -v qrencode &>/dev/null; then
        log_info "$(msg install_deps)"
        $PKG_UPDATE >/dev/null 2>&1 || true
        $PKG_INSTALL qrencode >/dev/null 2>&1
    fi

    show_node_qrcodes
}

# 列出所有节点
cmd_list() {
    local nodes
    read -ra nodes <<< "$(list_nodes)"

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_error "$(msg config_not_found)"
        return 1
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     All Nodes / 所有节点${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local i=1
    for node in "${nodes[@]}"; do
        local node_file
        node_file=$(get_node_file "$node")
        # 使用安全的配置加载（防止命令注入）
        safe_load_node_config "$node_file"
        # 根据协议类型显示对应的端口
        local display_port=""
        local proto="${PROTOCOL_TYPE:-vision}"
        if [[ "$proto" == "shadowsocks" ]]; then
            display_port="${PORT:-N/A}"
        elif [[ "$proto" == "hysteria2" ]]; then
            display_port="${PORT:-N/A} (UDP)"
        elif [[ "$proto" == "xhttp" ]]; then
            display_port="${XHTTP_PORT:-N/A}"
        elif [[ "$proto" == "both" ]]; then
            display_port="${PORT:-}/${XHTTP_PORT:-}"
        else
            display_port="${PORT:-N/A}"
        fi
        echo -e "  ${GREEN}$i.${NC} ${BLUE}$node${NC}"
        if [[ "$proto" == "shadowsocks" ]]; then
            echo -e "     Port: $display_port | Method: ${SS_METHOD:-N/A}"
            echo -e "     Password: ${SS_PASSWORD:0:12}..."
        elif [[ "$proto" == "hysteria2" ]]; then
            echo -e "     Port: $display_port | Type: Hysteria2"
            echo -e "     Password: ${HY2_PASSWORD:0:12}..."
        elif [[ "$proto" == "anytls" || "$proto" == "anytls_reality" ]]; then
            local at_label="AnyTLS"
            [[ "$proto" == "anytls_reality" ]] && at_label="AnyTLS + REALITY"
            echo -e "     Port: $display_port | Type: $at_label"
            echo -e "     Password: ${ANYTLS_PASSWORD:0:12}..."
            [[ "$proto" == "anytls_reality" ]] && echo -e "     SNI: $SNI"
        else
            echo -e "     Port: $display_port | SNI: $SNI"
            echo -e "     UUID: ${UUID:0:8}..."
            if [[ -n "$XHTTP_PORT" ]] && [[ "$proto" != "vision" ]]; then
                echo -e "     XHTTP: $XHTTP_PORT"
            fi
        fi
        echo ""
        ((++i))
    done

    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

cmd_status() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg service_status)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ "$(xray_node_count)" -gt 0 ]]; then
        if service_is_active xray; then
            echo -e "  Xray: ${GREEN}● Running${NC}"
        else
            echo -e "  Xray: ${RED}○ Stopped${NC}"
        fi
    fi

    if [[ "$(singbox_node_count)" -gt 0 ]]; then
        if service_is_active "$SINGBOX_SERVICE"; then
            echo -e "  sing-box (AnyTLS/Hysteria2): ${GREEN}● Running${NC}"
        else
            echo -e "  sing-box (AnyTLS/Hysteria2): ${RED}○ Stopped${NC}"
        fi
    fi

    local node_count
    node_count=$(count_nodes)
    echo -e "  Nodes: ${GREEN}${node_count}${NC}"

    # 显示每个节点的连接数
    if [[ $node_count -gt 0 ]]; then
        echo ""
        echo -e "  ${BLUE}Active connections:${NC}"
        for node_file in "$NODES_DIR"/*.env; do
            [[ -f "$node_file" ]] || continue
            local n_name n_port n_proto
            n_name=$(basename "$node_file" .env)
            n_port=$(safe_read_config_value "$node_file" "PORT")
            n_proto=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")
            if [[ "$n_proto" == "hysteria2" ]]; then
                echo -e "    $n_name (UDP $n_port): Hysteria2"
                continue
            fi
            local conn_count
            conn_count=$(ss -tn state established "( sport = :${n_port} )" 2>/dev/null | tail -n +2 | wc -l)
            echo -e "    $n_name (Port $n_port): ${GREEN}${conn_count}${NC}"
        done
    fi

    echo ""
    [[ "$(xray_node_count)" -gt 0 ]] && service_status xray
    [[ "$(singbox_node_count)" -gt 0 ]] && service_status "$SINGBOX_SERVICE"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

cmd_restart() {
    local restarted=false
    if [[ "$(xray_node_count)" -gt 0 ]]; then
        service_restart xray || return 1
        restarted=true
    fi
    if [[ "$(singbox_node_count)" -gt 0 ]]; then
        service_restart "$SINGBOX_SERVICE" || return 1
        restarted=true
    fi
    if ! $restarted; then
        log_error "No configured proxy nodes"
        return 1
    fi
    log_info "$(msg service_restarted)"
}

# 重新生成配置文件（用于修复配置问题）
cmd_regenerate() {
    log_info "Regenerating proxy configs from node files..."

    local xray_count
    xray_count=$(xray_node_count)

    # 仅在存在 Xray 节点时重建并验证 Xray；Hysteria2-only 不应依赖 Xray。
    if [[ "$xray_count" -gt 0 && -f "$XRAY_CONF" ]]; then
        cp "$XRAY_CONF" "${XRAY_CONF}.bak"
        log_info "Backed up current config to ${XRAY_CONF}.bak"
    fi

    if [[ "$xray_count" -gt 0 ]]; then
        if write_config; then
            log_info "Xray config regenerated successfully"
            if ! service_restart xray; then
                log_error "Xray service restart failed. Restoring backup..."
                [[ -f "${XRAY_CONF}.bak" ]] && mv "${XRAY_CONF}.bak" "$XRAY_CONF"
                service_restart xray >/dev/null 2>&1 || true
                return 1
            fi
            sleep 1
            if ! service_is_active xray; then
                log_error "Xray service failed to start. Restoring backup..."
                if [[ -f "${XRAY_CONF}.bak" ]]; then
                    mv "${XRAY_CONF}.bak" "$XRAY_CONF"
                    service_restart xray >/dev/null 2>&1 || true
                fi
                return 1
            fi
        else
            log_error "Failed to regenerate Xray config"
            if [[ -f "${XRAY_CONF}.bak" ]]; then
                log_info "Restoring backup config..."
                mv "${XRAY_CONF}.bak" "$XRAY_CONF"
            fi
            return 1
        fi
    else
        service_stop xray
    fi

    # 同步 sing-box（AnyTLS / Hysteria2）配置。
    if ! singbox_sync; then
        log_error "sing-box config sync failed"
        return 1
    fi

    # 清理备份
    rm -f "${XRAY_CONF}.bak" 2>/dev/null
    return 0
}

# 删除单个节点
cmd_remove() {
    select_node || return 1

    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")

    {
    echo ""
    echo -e "${YELLOW}About to remove node: $CURRENT_NODE_NAME${NC}"
    echo -n "Confirm? [y/N]: "
    } >/dev/tty
    read -r confirm </dev/tty

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        return 0
    fi

    rm -f "$node_file"
    # 清理可能存在的 AnyTLS / Hysteria2 自签名证书
    rm -f "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.crt" "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.key" 2>/dev/null
    log_info "Node '$CURRENT_NODE_NAME' removed"

    if ! cmd_regenerate; then
        log_error "Node removed, but the remaining proxy configuration could not be applied"
        return 1
    fi

    log_info "Config updated"
}

# 编辑已有节点的参数（端口 / SNI / 密码 / 密钥 / padding 等）
cmd_edit() {
    select_node || return 1
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    safe_load_node_config "$node_file"

    # safe_load 不含 padding；并解密敏感值，便于重存时正确再加密（明文配置下为 no-op）
    ANYTLS_PADDING_B64=$(safe_read_config_value "$node_file" "ANYTLS_PADDING_B64")
    UUID=$(decrypt_value "$UUID")
    PRIVATE_KEY=$(decrypt_value "$PRIVATE_KEY")
    SS_PASSWORD=$(decrypt_value "$SS_PASSWORD")
    ANYTLS_PASSWORD=$(decrypt_value "$ANYTLS_PASSWORD")
    HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")

    local proto_type="${PROTOCOL_TYPE:-vision}"
    local changed=false
    local sni_changed=false

    while true; do
        {
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}        编辑节点 / Edit Node: ${CURRENT_NODE_NAME} [${proto_type}]${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        case "$proto_type" in
            vision)
                echo -e "  ${GREEN}1.${NC} 修改端口 / Port            ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 SNI / dest            ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成 UUID              ${GRAY}(${UUID:0:8}...)${NC}"
                echo -e "  ${GREEN}4.${NC} 重新生成 Reality 密钥对"
                ;;
            xhttp)
                echo -e "  ${GREEN}1.${NC} 修改端口 / XHTTP Port      ${GRAY}(${XHTTP_PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 SNI / dest            ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成 UUID              ${GRAY}(${UUID:0:8}...)${NC}"
                echo -e "  ${GREEN}4.${NC} 重新生成 Reality 密钥对"
                echo -e "  ${GREEN}5.${NC} 重新生成 XHTTP path        ${GRAY}(${XHTTP_PATH})${NC}"
                ;;
            both)
                echo -e "  ${GREEN}1.${NC} 修改 Vision 端口           ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 XHTTP 端口            ${GRAY}(${XHTTP_PORT})${NC}"
                echo -e "  ${GREEN}3.${NC} 修改 SNI / dest            ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}4.${NC} 重新生成 UUID              ${GRAY}(${UUID:0:8}...)${NC}"
                echo -e "  ${GREEN}5.${NC} 重新生成 Reality 密钥对"
                ;;
            shadowsocks)
                echo -e "  ${GREEN}1.${NC} 修改端口 / Port            ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改加密方式 / Method      ${GRAY}(${SS_METHOD})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成密码 / Password"
                ;;
            anytls|anytls_reality)
                echo -e "  ${GREEN}1.${NC} 修改端口 / Port            ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 SNI                   ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成密码 / Password"
                echo -e "  ${GREEN}4.${NC} 重新生成 padding scheme"
                [[ "$proto_type" == "anytls_reality" ]] && echo -e "  ${GREEN}5.${NC} 重新生成 Reality 密钥对"
                ;;
            hysteria2)
                echo -e "  ${GREEN}1.${NC} 修改 UDP 端口 / UDP Port    ${GRAY}(${PORT})${NC}"
                echo -e "  ${GREEN}2.${NC} 修改 TLS SNI               ${GRAY}(${SNI})${NC}"
                echo -e "  ${GREEN}3.${NC} 重新生成密码 / Password"
                ;;
            *)
                log_error "未知协议类型: $proto_type"
                return 1
                ;;
        esac
        echo -e "  ${GREEN}0.${NC} 完成并应用 / Save & apply"
        echo ""
        echo -n "  选择要修改的项 / Select [0-5]: "
        } >/dev/tty

        local c
        read -r c </dev/tty

        case "${proto_type}:${c}" in
            *:0) break ;;

            # ---- 端口 ----
            xhttp:1)
                XHTTP_PORT=$(prompt_port "新 XHTTP 端口 / New port" "${XHTTP_PORT}")
                changed=true ;;
            both:1)
                PORT=$(prompt_port "新 Vision 端口 / New port" "${PORT}" "${XHTTP_PORT:-0}")
                changed=true ;;
            both:2)
                XHTTP_PORT=$(prompt_port "新 XHTTP 端口 / New port" "${XHTTP_PORT}" "${PORT:-0}")
                changed=true ;;
            vision:1|shadowsocks:1|anytls:1|anytls_reality:1)
                PORT=$(prompt_port "新端口 / New port" "${PORT}")
                changed=true ;;
            hysteria2:1)
                PORT=$(prompt_port "新 UDP 端口 / New UDP port" "${PORT}" 0 udp)
                changed=true ;;

            # ---- SNI（测速 + 自定义）----
            vision:2|xhttp:2|both:3|anytls:2|anytls_reality:2)
                rm -f "$CACHE_FILE" 2>/dev/null
                [[ "$proto_type" == "anytls" ]] && log_info "$(msg anytls_sni_note)"
                select_best_sni
                sni_changed=true
                changed=true ;;
            hysteria2:2)
                local new_hy2_sni
                echo -n "  TLS SNI [${SNI:-www.bing.com}]: " >/dev/tty
                read -r new_hy2_sni </dev/tty
                new_hy2_sni="${new_hy2_sni:-${SNI:-www.bing.com}}"
                if validate_tls_server_name "$new_hy2_sni"; then
                    SNI="$new_hy2_sni"
                    sni_changed=true
                    changed=true
                else
                    log_warn "Invalid TLS SNI"
                fi ;;

            # ---- UUID ----
            vision:3|xhttp:3|both:4)
                UUID=$(cat /proc/sys/kernel/random/uuid)
                log_info "新 UUID: $UUID"
                changed=true ;;

            # ---- Reality 密钥对 ----
            vision:4|xhttp:4|both:5|anytls_reality:5)
                if gen_reality_keys; then
                    log_warn "Reality 密钥已更新，客户端需同步新的 PublicKey/ShortID"
                    changed=true
                fi ;;

            # ---- XHTTP path ----
            xhttp:5)
                XHTTP_PATH="/$(openssl rand -hex 4)"
                log_info "新 path: $XHTTP_PATH"
                changed=true ;;

            # ---- Shadowsocks 加密方式（同时重新生成匹配长度的密码）----
            shadowsocks:2)
                prompt_ss_method
                gen_ss_password
                log_warn "加密方式已变更，密码已随之重新生成"
                changed=true ;;

            # ---- 密码（SS / AnyTLS）----
            shadowsocks:3)
                gen_ss_password
                log_info "密码已重新生成"
                changed=true ;;
            anytls:3|anytls_reality:3)
                gen_anytls_password
                changed=true ;;
            hysteria2:3)
                unset hy2pwd
                gen_hy2_password
                changed=true ;;

            # ---- AnyTLS padding ----
            anytls:4|anytls_reality:4)
                ANYTLS_PADDING_B64="$(gen_anytls_padding | base64 -w0)"
                log_info "padding scheme 已重新随机生成"
                changed=true ;;

            *)
                log_warn "无效选择 / invalid choice"
                sleep 1 ;;
        esac
    done

    if ! $changed; then
        log_info "未做任何修改 / No changes"
        return 0
    fi

    # 写回 .env（save_env 会按当前全局变量重写该节点配置）
    save_env

    # 重新生成对应内核配置并重启
    if [[ "$proto_type" == "anytls" || "$proto_type" == "anytls_reality" || "$proto_type" == "hysteria2" ]]; then
        # 自签名 TLS 协议改了 SNI：重新生成证书（CN 跟随新 SNI）。
        if [[ "$proto_type" == "anytls" || "$proto_type" == "hysteria2" ]] && $sni_changed; then
            rm -f "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.crt" "$SINGBOX_CERT_DIR/${CURRENT_NODE_NAME}.key" 2>/dev/null
            gen_selfsigned_cert "$CURRENT_NODE_NAME" "$SNI" || return 1
        fi
        if ! singbox_sync; then
            log_error "应用失败：sing-box 配置无效，请检查参数"
            return 1
        fi
        open_node_firewall_ports "$proto_type"
    else
        if ! write_config; then
            log_error "应用失败：Xray 配置无效，请检查参数"
            return 1
        fi
        service_restart xray || return 1
        open_node_firewall_ports "$proto_type"
    fi

    log_info "节点已更新 / Node updated"
    show_info
}

cmd_uninstall() {
    log_info "$(msg uninstalling)"
    # 清理定时重启计划（service/timer 或 crontab 条目）
    remove_xray_restart_schedule
    service_stop xray
    service_disable xray
    rm -f "$XRAY_CONF" "$LANG_FILE"
    rm -rf "$NODES_DIR"

    # Alpine 使用手动安装，需要手动清理
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        rm -f /usr/local/bin/xray
        rm -rf /usr/local/etc/xray
        rm -rf /usr/local/share/xray
        rm -rf /var/log/xray
        rm -f /etc/init.d/xray
    else
        # Security: Download script to temp file first, then execute
        local tmp_installer="/tmp/xray-uninstall-$$.sh"
        if secure_curl "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "$tmp_installer"; then
            bash "$tmp_installer" remove >/dev/null 2>&1
            rm -f "$tmp_installer"
        fi
    fi

    # 卸载 sing-box（AnyTLS / Hysteria2）
    if [[ -f "$SINGBOX_BIN" ]] || [[ -f /etc/systemd/system/sing-box.service ]] || [[ -f /etc/init.d/sing-box ]]; then
        service_stop "$SINGBOX_SERVICE"
        service_disable "$SINGBOX_SERVICE"
        rm -f "$SINGBOX_BIN"
        rm -rf "$SINGBOX_DIR"
        rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box
        rm -f /var/log/sing-box.log
        systemctl daemon-reload 2>/dev/null || true
    fi

    log_info "$(msg uninstall_complete)"
}

cmd_test_sni() {
    local total=${#SNI_LIST[@]}
    log_info "$(msg testing_sni) ($(msg total_domains): $total)"
    echo ""

    declare -A latency_map

    # 使用并行测试（带详细输出）
    test_domains_parallel_verbose latency_map

    echo ""

    # 显示排序结果（前10名）
    if [[ ${#latency_map[@]} -gt 0 ]]; then
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     Top 10 $(msg best_latency)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""

        # 排序并显示前10
        for domain in "${!latency_map[@]}"; do
            echo "${latency_map[$domain]} $domain"
        done | sort -n | head -10 | while read -r lat dom; do
            printf "  ${GREEN}%4dms${NC}  %s\n" "$lat" "$dom"
        done

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    fi

    log_info "$(msg test_complete)"
}

cmd_health() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg health_check)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local all_ok=true

    # 1. 仅检查实际被节点使用的代理内核。
    if [[ "$(xray_node_count)" -gt 0 ]]; then
        if service_is_active xray; then
            echo -e "  ${GREEN}✓${NC} Xray service is running"
        else
            echo -e "  ${RED}✗${NC} Xray service is not running"
            all_ok=false
        fi
    fi

    if [[ "$(singbox_node_count)" -gt 0 ]]; then
        if service_is_active "$SINGBOX_SERVICE"; then
            echo -e "  ${GREEN}✓${NC} sing-box service is running (AnyTLS/Hysteria2)"
        else
            echo -e "  ${RED}✗${NC} sing-box service is not running (AnyTLS/Hysteria2)"
            all_ok=false
        fi
    fi

    # 2. 检查节点数量
    local node_count
    node_count=$(count_nodes)
    if [[ $node_count -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $node_count node(s) configured"
    else
        echo -e "  ${RED}✗${NC} No nodes configured"
        all_ok=false
    fi

    # 3. 检查每个节点的端口和 SNI
    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        local n_name n_port n_sni n_xhttp_port n_protocol_type
        n_name=$(basename "$node_file" .env)
        n_port=$(safe_read_config_value "$node_file" "PORT")
        n_sni=$(safe_read_config_value "$node_file" "SNI")
        n_xhttp_port=$(safe_read_config_value "$node_file" "XHTTP_PORT")
        n_protocol_type=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")

        # 向后兼容：旧配置没有 PROTOCOL_TYPE，根据端口判断
        if [[ -z "$n_protocol_type" ]]; then
            if [[ -n "$n_port" ]] && [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="both"
            elif [[ -n "$n_xhttp_port" ]]; then
                n_protocol_type="xhttp"
            else
                n_protocol_type="vision"
            fi
        fi

        echo ""
        echo -e "  ${BLUE}Node: $n_name${NC} (${n_protocol_type})"

        # 根据协议类型检查端口
        if [[ "$n_protocol_type" == "vision" || "$n_protocol_type" == "both" ]] && [[ -n "$n_port" ]]; then
            if ss -lnt | grep -qE ":${n_port}\s"; then
                echo -e "    ${GREEN}✓${NC} Vision port $n_port is listening"
            else
                echo -e "    ${RED}✗${NC} Vision port $n_port is not listening"
                all_ok=false
            fi
        fi

        if [[ "$n_protocol_type" == "xhttp" || "$n_protocol_type" == "both" ]] && [[ -n "$n_xhttp_port" ]]; then
            if ss -lnt | grep -qE ":${n_xhttp_port}\s"; then
                echo -e "    ${GREEN}✓${NC} XHTTP port $n_xhttp_port is listening"
            else
                echo -e "    ${RED}✗${NC} XHTTP port $n_xhttp_port is not listening"
                all_ok=false
            fi
        fi

        if [[ "$n_protocol_type" == "anytls" || "$n_protocol_type" == "anytls_reality" ]] && [[ -n "$n_port" ]]; then
            if ss -lnt | grep -qE ":${n_port}\s"; then
                echo -e "    ${GREEN}✓${NC} AnyTLS port $n_port is listening"
            else
                echo -e "    ${RED}✗${NC} AnyTLS port $n_port is not listening"
                all_ok=false
            fi
        fi

        if [[ "$n_protocol_type" == "hysteria2" ]] && [[ -n "$n_port" ]]; then
            if ss -lnu 2>/dev/null | grep -qE ":${n_port}([[:space:]]|$)"; then
                echo -e "    ${GREEN}✓${NC} Hysteria2 UDP port $n_port is listening"
            else
                echo -e "    ${RED}✗${NC} Hysteria2 UDP port $n_port is not listening"
                all_ok=false
            fi
            continue
        fi

        # 测试 SNI 连接
        if [[ -n "$n_sni" ]] && timeout 3 openssl s_client -connect "${n_sni}:443" -servername "$n_sni" </dev/null &>/dev/null; then
            echo -e "    ${GREEN}✓${NC} SNI ($n_sni) is reachable"
        elif [[ -n "$n_sni" ]]; then
            echo -e "    ${YELLOW}!${NC} SNI ($n_sni) connection timeout"
        fi
    done

    echo ""
    if $all_ok; then
        echo -e "  ${GREEN}All checks passed! Nodes are healthy.${NC}"
    else
        echo -e "  ${RED}Some checks failed. Please review above.${NC}"
    fi
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# ============== IP 变更检测与更新 ==============

cmd_update_ip() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     $(msg update_ip)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # 检查是否有节点
    local node_count
    node_count=$(count_nodes)
    if [[ $node_count -eq 0 ]]; then
        log_error "$(msg update_ip_no_nodes)"
        return 1
    fi

    # 检测当前公网 IP
    log_info "$(msg update_ip_detecting)"
    local current_ipv4 current_ipv6
    current_ipv4=$(get_ipv4)
    current_ipv6=$(get_ipv6)

    if [[ -z "$current_ipv4" ]] && [[ -z "$current_ipv6" ]]; then
        log_error "$(msg update_ip_detect_fail)"
        return 1
    fi

    [[ -n "$current_ipv4" ]] && echo -e "  ${BLUE}$(msg update_ip_current) IPv4:${NC} $current_ipv4"
    [[ -n "$current_ipv6" ]] && echo -e "  ${BLUE}$(msg update_ip_current) IPv6:${NC} $current_ipv6"
    echo ""

    # 逐节点对比并更新各自存储的 IP。
    #
    # 旧实现以"第一个节点"的存储 IP 作为全局基准来判断是否变更：当基准节点
    # 恰好已经是新 IP（例如在换 IP 之后才新增的节点排在最前）时，会被误判为
    # "无变化"而提前返回，导致换 IP 之前就存在的旧节点不会被同步，其分享链接
    # 仍显示旧 IP。这里改为对每个节点用其自身存储的 IP 单独比较与更新。
    log_info "$(msg update_ip_updating)"
    local updated_count=0

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue
        local n_name n_v4 n_v6 n_changed detail
        n_name=$(basename "$node_file" .env)
        n_v4=$(safe_read_config_value "$node_file" "SERVER_IPV4")
        # 向后兼容：没有 SERVER_IPV4 时回退到 SERVER_IP
        [[ -z "$n_v4" ]] && n_v4=$(safe_read_config_value "$node_file" "SERVER_IP")
        n_v6=$(safe_read_config_value "$node_file" "SERVER_IPV6")
        n_changed=false
        detail=""

        # IPv4：仅当检测到当前 IPv4 且与该节点存储值不同时才更新
        if [[ -n "$current_ipv4" ]] && [[ "$current_ipv4" != "$n_v4" ]]; then
            if grep -q "^SERVER_IP=" "$node_file"; then
                sed -i "s|^SERVER_IP=.*|SERVER_IP=${current_ipv4}|" "$node_file"
            else
                echo "SERVER_IP=${current_ipv4}" >> "$node_file"
            fi
            if grep -q "^SERVER_IPV4=" "$node_file"; then
                sed -i "s|^SERVER_IPV4=.*|SERVER_IPV4=${current_ipv4}|" "$node_file"
            else
                echo "SERVER_IPV4=${current_ipv4}" >> "$node_file"
            fi
            detail+="\n    IPv4: ${RED}${n_v4:-N/A}${NC} → ${GREEN}${current_ipv4}${NC}"
            n_changed=true
        fi

        # IPv6：同理
        if [[ -n "$current_ipv6" ]] && [[ "$current_ipv6" != "$n_v6" ]]; then
            if grep -q "^SERVER_IPV6=" "$node_file"; then
                sed -i "s|^SERVER_IPV6=.*|SERVER_IPV6=${current_ipv6}|" "$node_file"
            else
                echo "SERVER_IPV6=${current_ipv6}" >> "$node_file"
            fi
            detail+="\n    IPv6: ${RED}${n_v6:-N/A}${NC} → ${GREEN}${current_ipv6}${NC}"
            n_changed=true
        fi

        if $n_changed; then
            echo -e "  ${GREEN}✓${NC} $(msg update_ip_node_updated): ${n_name}${detail}"
            updated_count=$((updated_count + 1))
        fi
    done

    # 所有节点的 IP 均已是最新，无需任何更新
    if [[ $updated_count -eq 0 ]]; then
        echo ""
        echo -e "  ${GREEN}✓${NC} $(msg update_ip_no_change)"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        return 0
    fi

    echo ""
    log_info "$(msg update_ip_done) ($updated_count)"

    # 更新全局变量
    [[ -n "$current_ipv4" ]] && SERVER_IPV4="$current_ipv4"
    [[ -n "$current_ipv6" ]] && SERVER_IPV6="$current_ipv6"
    SERVER_IP="${current_ipv4:-$SERVER_IP}"

    # 重新同步所有实际使用的代理内核。
    log_info "$(msg update_ip_regen)"
    if cmd_regenerate; then
        echo ""
        echo -e "  ${GREEN}✓${NC} $(msg update_ip_complete)"
    else
        log_error "Failed to synchronize proxy config after IP update"
        return 1
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

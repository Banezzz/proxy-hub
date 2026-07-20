# ============== 系统工具菜单 ==============

cmd_tools() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg tools_menu)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${BLUE}[网络优化]${NC}"
        echo -e "  ${GREEN}1.${NC} $(msg menu_warp)"
        echo -e "  ${GREEN}2.${NC} $(msg menu_bbr)"
        echo ""
        echo -e "  ${BLUE}[系统管理]${NC}"
        echo -e "  ${GREEN}3.${NC} $(msg menu_swap)"
        echo -e "  ${GREEN}4.${NC} $(msg menu_fail2ban)"
        echo -e "  ${GREEN}5.${NC} $(msg menu_timesync)"
        echo ""
        echo -e "  ${BLUE}[服务管理]${NC}"
        echo -e "  ${GREEN}6.${NC} 端口管理 (Ports)"
        echo -e "  ${GREEN}7.${NC} 日志查看 (Logs)"
        echo -e "  ${GREEN}8.${NC} $(msg xray_restart_title)"
        echo ""
        echo -e "  ${BLUE}[其他]${NC}"
        echo -e "  ${GREEN}9.${NC} 安装独立工具命令"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-9]: "
        read -r choice

        case "$choice" in
            1) cmd_warp ;;
            2) cmd_bbr ;;
            3) cmd_swap ;;
            4) cmd_fail2ban ;;
            5) cmd_timesync ;;
            6) cmd_ports ;;
            7) cmd_logs ;;
            8) cmd_xray_restart ;;
            9)
                install_standalone_tools
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ============== 主菜单 ==============

show_menu() {
    clear
    local status_icon node_count
    if service_is_active xray; then
        status_icon="${GREEN}●${NC}"
    else
        status_icon="${RED}○${NC}"
    fi
    node_count=$(count_nodes)

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}         ${YELLOW}$(msg menu_title)${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}1.${NC} $(msg menu_install) (Add Node)                                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}2.${NC} $(msg menu_info)                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}3.${NC} $(msg menu_qr)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}4.${NC} $(msg menu_status)  [$status_icon] (${node_count} nodes)                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}5.${NC} List Nodes / 列出节点                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}6.${NC} Remove Node / 删除节点                                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}E.${NC} Edit Node / 编辑节点                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}7.${NC} $(msg menu_restart)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}8.${NC} $(msg menu_test_sni)                                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}9.${NC} $(msg menu_health)                                             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}   ${BLUE}I.${NC} $(msg update_ip) / 更新节点 IP                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${BLUE}T.${NC} $(msg menu_tools) (WARP/BBR/Swap/Fail2ban/TimeSync)          ${CYAN}║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}L.${NC} $(msg menu_lang)                                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${YELLOW}U.${NC} $(msg menu_uninstall) (All)                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${RED}0.${NC} $(msg menu_exit)                                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main_menu() {
    while true; do
        show_menu
        echo -n "   $(msg menu_choice) [0-9,E,I,T,L,U]: "
        read -r choice
        echo ""

        case "$choice" in
            1)
                cmd_install
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            2)
                cmd_info
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            3)
                cmd_qr
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            4)
                cmd_status
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            5)
                cmd_list
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            6)
                cmd_remove
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            7)
                cmd_restart
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            8)
                cmd_test_sni
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            9)
                cmd_health
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            [Ee])
                cmd_edit
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            [Ii])
                cmd_update_ip
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            [Tt])
                cmd_tools
                ;;
            [Ll])
                select_language
                ;;
            [Uu])
                cmd_uninstall
                echo ""
                read -rp "$(msg menu_press_enter)"
                ;;
            0)
                echo -e "${GREEN}Bye!${NC}"
                exit 0
                ;;
            *)
                log_error "$(msg menu_invalid)"
                sleep 1
                ;;
        esac
    done
}

show_help() {
    echo ""
    echo -e "${CYAN}VLESS TCP REALITY Vision (Enhanced Edition)${NC}"
    echo ""
    echo "Usage: bash $0 [command]"
    echo ""
    echo "Commands:"
    echo "  (none)      Show interactive menu"
    echo "  install     Add a new node"
    echo "  list        List all nodes"
    echo "  info        Show node information"
    echo "  qr          Show QR code"
    echo "  status      Show service status"
    echo "  health      Run health check"
    echo "  remove      Remove a node"
    echo "  edit        Edit an existing node (port/SNI/password/keys...)"
    echo "  restart     Restart service"
    echo "  regenerate  Regenerate config from node files (fix config issues)"
    echo "  update-ip   Detect IP change and update all node configs"
    echo "  uninstall   Uninstall all nodes and Xray"
    echo "  test-sni    Test all SNI latency"
    echo ""
    echo "System Tools:"
    echo "  tools       System tools menu (WARP/BBR/Swap/Fail2ban/TimeSync/Ports/Logs)"
    echo "  ports       Port management (SSH/Vision/XHTTP)"
    echo "  logs        Log viewer"
    echo "  warp        WARP routing management"
    echo "  bbr         BBR/TCP optimization"
    echo "  swap        Swap management"
    echo "  fail2ban    Fail2ban management"
    echo "  timesync    System time synchronization (NTP/Chrony)"
    echo "  xray-restart  Schedule periodic Xray restart (systemd timer or cron)"
    echo ""
    echo "Other:"
    echo "  menu        Show interactive menu"
    echo "  help        Show this help"
    echo ""
    echo "Optional parameters (for install):"
    echo "  name=xxx      Specify node name"
    echo "  reym=xxx      Specify SNI domain (VLESS / AnyTLS+REALITY)"
    echo "  proto=xxx     Protocol type: vision, xhttp, both, shadowsocks,"
    echo "                anytls, anytls-reality, or hysteria2 (hy2)"
    echo "  vlpt=xxx      Specify Vision port (for vision/both)"
    echo "  xhpt=xxx      Specify XHTTP port (for xhttp/both)"
    echo "  uuid=xxx      Specify UUID (VLESS only)"
    echo ""
    echo "Shadowsocks parameters:"
    echo "  ssmethod=xxx  Encryption: 2022-blake3-aes-256-gcm (default),"
    echo "                2022-blake3-chacha20-poly1305, chacha20-ietf-poly1305, aes-256-gcm"
    echo "  sspwd=xxx     Specify password (auto-generated if not set)"
    echo "  sspt=xxx      Specify Shadowsocks port"
    echo "  xhttp=true    (deprecated) Same as proto=both"
    echo ""
    echo "AnyTLS parameters (powered by sing-box; Xray does not support AnyTLS):"
    echo "  atpt=xxx      Specify AnyTLS port"
    echo "  atpwd=xxx     Specify AnyTLS password (auto-generated if not set)"
    echo "                Padding scheme is randomized per node and auto-pushed to clients"
    echo ""
    echo "Hysteria2 parameters (powered by sing-box):"
    echo "  hy2pt=xxx     Specify Hysteria2 UDP port"
    echo "  hy2pwd=xxx    Specify 8-128 character URI-safe password"
    echo "  hy2sni=xxx    Specify TLS SNI (default: www.bing.com)"
    echo ""
    echo "Periodic Xray restart (optional, non-interactive):"
    echo "  restart=daily   Daily restart (04:00)"
    echo "  restart=12h     Every 12 hours"
    echo "  restart=6h      Every 6 hours"
    echo "  restart=weekly  Weekly restart (Sun 04:00)"
    echo "  restart=no      Skip the restart schedule prompt"
    echo ""
    echo "Examples:"
    echo "  bash $0                                    # Interactive menu"
    echo "  bash $0 install                            # Add node (interactive)"
    echo "  name=hk1 bash $0 install                   # Add Vision node with name"
    echo "  name=jp1 proto=xhttp bash $0 install       # Add XHTTP only node"
    echo "  name=sg1 proto=both bash $0 install        # Add Vision + XHTTP node"
    echo "  name=at1 proto=anytls bash $0 install      # Add AnyTLS node (self-signed)"
    echo "  name=ar1 proto=anytls-reality bash $0 install  # Add AnyTLS + REALITY node"
    echo "  name=hy2 proto=hysteria2 bash $0 install   # Add Hysteria2 UDP node"
    echo "  bash $0 tools                              # System tools menu"
    echo "  bash $0 ports                              # Port management"
    echo "  bash $0 logs                               # Log viewer"
    echo ""
}

# ============== 主入口 ==============

# 加载语言设置
load_lang

# 如果没有语言设置且是交互模式，先选择语言
init_language_if_needed() {
    if [[ -z "$CURRENT_LANG" ]]; then
        select_language
    fi
}

# 单实例锁检查（对于可能冲突的操作）
check_lock_for_write_ops() {
    if ! lock_acquire_smart; then
        log_error "$(msg script_running)"
        log_error "Lock path: ${LOCK_FILE:-${LOCK_DIR:-unknown}}"
        exit 1
    fi
}

case "${1:-}" in
    install)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_install
        ;;
    list)
        init_language_if_needed
        cmd_list
        ;;
    info)
        init_language_if_needed
        cmd_info
        ;;
    qr)
        init_language_if_needed
        cmd_qr
        ;;
    status)
        init_language_if_needed
        cmd_status
        ;;
    health)
        init_language_if_needed
        cmd_health
        ;;
    remove)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_remove
        ;;
    edit)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_edit
        ;;
    restart)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_restart
        ;;
    regenerate|regen)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_regenerate
        ;;
    update-ip)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_update_ip
        ;;
    uninstall)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_uninstall
        ;;
    test-sni)
        init_language_if_needed
        cmd_test_sni
        ;;
    tools)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_tools
        ;;
    warp)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_warp
        ;;
    bbr)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_bbr
        ;;
    swap)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_swap
        ;;
    fail2ban)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_fail2ban
        ;;
    timesync)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_timesync
        ;;
    xray-restart|restart-schedule)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_xray_restart
        ;;
    ports)
        check_lock_for_write_ops
        init_language_if_needed
        cmd_ports
        ;;
    logs)
        init_language_if_needed
        cmd_logs
        ;;
    menu|"")
        check_lock_for_write_ops
        init_language_if_needed
        main_menu
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        ;;
esac

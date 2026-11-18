# ============== 协议可选增强 ==============
#
# 安装节点时的可选增强项（后量子、Hysteria2 加固）集中在这里：它们默认关闭，各自对
# 客户端或网络环境有要求。本模块在 50_node_commands.sh 之后装载，但这些函数只在
# 运行期被 cmd_install / cmd_edit 调用，不存在 source 阶段的反向依赖。

# ---- 后量子增强 ----

# REALITY 目标在握手中返回的证书链总字节数。ML-DSA-65 签名约 3309 字节，以证书扩展
# 的形式附加；Xray 文档要求目标返回的证书必须长于 3500 字节，否则放不下。
# Usage: reality_target_cert_bytes DOMAIN   -> 字节数（探测失败为 0）
reality_target_cert_bytes() {
    local domain="$1" family_flag
    local -a family=()
    family_flag=$(netstack_openssl_family)
    [[ -n "$family_flag" ]] && family=("$family_flag")
    timeout 5 openssl s_client ${family[@]+"${family[@]}"} -connect "${domain}:443" \
        -servername "$domain" -showcerts </dev/null 2>/dev/null | awk '
            /-----BEGIN CERTIFICATE-----/ { inside = 1; next }
            /-----END CERTIFICATE-----/ { inside = 0; next }
            inside { chars += length($0) }
            END { print int(chars * 3 / 4) }'
}

# 生成 ML-DSA-65 密钥对：MLDSA65_SEED 留在服务端，MLDSA65_VERIFY 发给客户端。
gen_mldsa65_keys() {
    local out seed verify
    out=$("$XRAY_BIN" mldsa65 2>/dev/null | tr -d '\r') || return 1
    seed=$(awk -F': *' '$1 == "Seed" { print $2; exit }' <<<"$out")
    verify=$(awk -F': *' '$1 == "Verify" { print $2; exit }' <<<"$out")
    [[ "$seed" =~ ^[A-Za-z0-9_-]{40,}$ && "$verify" =~ ^[A-Za-z0-9_-]{1000,}$ ]] || return 1
    MLDSA65_SEED="$seed"
    MLDSA65_VERIFY="$verify"
}

# 生成 VLESS Encryption 的 decryption/encryption 串对。`xray vlessenc` 一次给出两种
# 认证方式，密钥交换都是后量子安全的 mlkem768x25519plus，区别只在认证密钥：
#   x25519  认证密钥 43 字符，链接短、二维码可扫（默认）
#   mlkem   认证也是后量子的，但客户端串约 1.6KB，链接无法生成可扫的二维码
# Usage: gen_vlessenc_keys x25519|mlkem
gen_vlessenc_keys() {
    local want="${1:-x25519}" out decryption encryption
    out=$("$XRAY_BIN" vlessenc 2>/dev/null | tr -d '\r') || return 1
    decryption=$(awk -v want="$want" '
        /^Authentication: X25519/ { section = "x25519" }
        /^Authentication: ML-KEM-768/ { section = "mlkem" }
        section == want && /"decryption"/ { split($0, part, "\""); print part[4]; exit }' <<<"$out")
    encryption=$(awk -v want="$want" '
        /^Authentication: X25519/ { section = "x25519" }
        /^Authentication: ML-KEM-768/ { section = "mlkem" }
        section == want && /"encryption"/ { split($0, part, "\""); print part[4]; exit }' <<<"$out")
    [[ "$decryption" =~ ^mlkem768x25519plus\.[A-Za-z0-9._-]{20,}$ ]] || return 1
    [[ "$encryption" =~ ^mlkem768x25519plus\.[A-Za-z0-9._-]{20,}$ ]] || return 1
    VLESS_DECRYPTION="$decryption"
    VLESS_ENCRYPTION="$encryption"
}

# 布尔型环境变量：true/1/y/yes/on 视为启用。
env_flag_enabled() {
    case "${1,,}" in
        true|1|y|yes|on) return 0 ;;
    esac
    return 1
}

# 交互式选择后量子增强，结果写入 PQ_WANT_MLDSA65 / PQ_WANT_VLESSENC。
# 只在完全交互的安装里出现：只要调用方用 proto= 或任一后量子环境变量驱动安装，就
# 不再追加提问，避免让既有的无人值守脚本卡在一个它们不知道的新提示上。
prompt_pq_options() {
    PQ_WANT_MLDSA65=""
    PQ_WANT_VLESSENC=""
    [[ -z "${proto:-}" && -z "${mldsa65:-}" && -z "${vlessenc:-}" ]] || return 0
    xray_supports vlessenc || xray_supports mldsa65 || return 0
    # 没有控制终端时无法提问。这里与协议/端口提示不同：选项的默认值就是"关闭"，
    # 跳过提问不会让用户得到一个自己没选过的东西，所以直接按默认处理。
    tty_available || return 0

    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        $(t2 "后量子增强（可选，回车跳过）" "Post-quantum options (optional, Enter to skip)")${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    menu_note "$(t2 "作用：防止今天被录下的流量在将来被量子计算机解密或伪造。" \
        "Purpose: keep traffic recorded today from being decrypted or forged by a future quantum computer.")" \
        "$(t2 "密钥全部自动生成，无需填写；代价是客户端必须足够新。" \
        "All keys are generated for you; the cost is that clients must be recent enough.")"
    echo ""
    echo -e "  ${GREEN}0.${NC} $(t2 "不启用（默认）" "Off (default)")"
    menu_note "$(t2 "兼容所有客户端。不确定客户端版本时选这个。" \
        "Works with every client. Pick this when unsure about client versions.")"
    echo -e "  ${GREEN}1.${NC} VLESS Encryption  ${YELLOW}$(t2 "[新客户端推荐]" "[recommended for recent clients]")${NC}"
    menu_note "$(t2 "给 VLESS 加一层后量子密钥交换，链接仍然很短、可以扫码。" \
        "Adds a post-quantum key exchange to VLESS; the link stays short and scannable.")" \
        "$(t2 "要求客户端内核为 Xray 25.9 或更新。" "Requires a client core of Xray 25.9 or newer.")"
    echo -e "  ${GREEN}2.${NC} REALITY ML-DSA-65"
    menu_note "$(t2 "给 REALITY 证书加后量子签名，防止服务器被冒充。" \
        "Adds a post-quantum signature to the REALITY certificate so the server cannot be impersonated.")" \
        "$(t2 "链接会变成约 3KB，无法生成二维码，只能复制粘贴导入。" \
        "The link grows to about 3 kB: no QR code, copy and paste only.")"
    echo -e "  ${GREEN}3.${NC} $(t2 "两项都启用" "Both")"
    echo ""
    echo -n "  $(t2 "请选择" "Select") [0-3] ($(t2 "默认" "default") 0): "
    } | tty_print

    local choice=""
    tty_read choice
    case "$choice" in
        1) PQ_WANT_VLESSENC="x25519" ;;
        2) PQ_WANT_MLDSA65="true" ;;
        3) PQ_WANT_VLESSENC="x25519"; PQ_WANT_MLDSA65="true" ;;
    esac
}

# 为当前正在安装的 VLESS + REALITY 节点应用可选的后量子增强。
#   vlessenc=x25519|mlkem|true  VLESS Encryption（true 等同 x25519）
#   mldsa65=true                REALITY ML-DSA-65 证书签名（客户端需要 mldsa65Verify）
# 默认全部关闭：它们都要求较新的客户端，旧客户端导入带这些参数的链接会连不上。
# 条件不满足（核心不支持、目标证书太短）时告警并跳过，不让整次安装失败。
configure_pq_options() {
    MLDSA65_SEED=""
    MLDSA65_VERIFY=""
    VLESS_DECRYPTION=""
    VLESS_ENCRYPTION=""

    local want_mldsa65="" want_vlessenc=""
    prompt_pq_options
    want_mldsa65="$PQ_WANT_MLDSA65"
    want_vlessenc="$PQ_WANT_VLESSENC"
    env_flag_enabled "${mldsa65:-}" && want_mldsa65="true"
    local vlessenc_request="${vlessenc:-}"
    vlessenc_request="${vlessenc_request,,}"
    case "$vlessenc_request" in
        x25519|mlkem) want_vlessenc="$vlessenc_request" ;;
        "") ;;
        *) env_flag_enabled "$vlessenc_request" && want_vlessenc="x25519" ;;
    esac

    if [[ -n "$want_vlessenc" ]]; then
        if ! xray_supports vlessenc; then
            log_warn "$(t2 "当前 Xray 不支持 VLESS Encryption，已跳过（可先执行 xray-update）" \
                "This Xray does not support VLESS Encryption; skipped (run xray-update first)")"
        elif ! gen_vlessenc_keys "$want_vlessenc"; then
            log_error "$(t2 "生成 VLESS Encryption 密钥失败" "Failed to generate VLESS Encryption keys")"
            return 1
        else
            log_info "$(t2 "已启用 VLESS Encryption（认证方式: $want_vlessenc）" \
                "VLESS Encryption enabled (authentication: $want_vlessenc)")"
        fi
    fi

    [[ -n "$want_mldsa65" ]] || return 0
    if ! xray_supports mldsa65; then
        log_warn "$(t2 "当前 Xray 不支持 ML-DSA-65，已跳过（可先执行 xray-update）" \
            "This Xray does not support ML-DSA-65; skipped (run xray-update first)")"
        return 0
    fi
    local chain_bytes
    chain_bytes=$(reality_target_cert_bytes "$SNI")
    if [[ ! "$chain_bytes" =~ ^[0-9]+$ ]] || (( chain_bytes <= 3500 )); then
        log_warn "$(t2 "目标 $SNI 返回的证书只有 ${chain_bytes:-0} 字节（需大于 3500），放不下 ML-DSA-65 签名，已跳过" \
            "Target $SNI returned only ${chain_bytes:-0} certificate bytes (more than 3500 required); ML-DSA-65 skipped")"
        return 0
    fi
    if ! gen_mldsa65_keys; then
        log_error "$(t2 "生成 ML-DSA-65 密钥失败" "Failed to generate ML-DSA-65 keys")"
        return 1
    fi
    log_info "$(t2 "已启用 REALITY ML-DSA-65（目标证书 ${chain_bytes} 字节）" \
        "REALITY ML-DSA-65 enabled (target certificate: ${chain_bytes} bytes)")"
}

# ---- Hysteria2 加固 ----
#
# Hysteria2 的默认形态（密码 + 自签名证书 + HTTP/3 伪装）在主动探测面前特征明显。

# 校验并采用一个端口跳跃范围，写入 HY2_HOP_PORTS。
# Usage: apply_hy2_hop_range RANGE
apply_hy2_hop_range() {
    local range request="${1:-}"
    if [[ "${request,,}" == "auto" ]]; then
        if ! request=$(gen_hy2_hop_range "${CURRENT_NODE_NAME:-}"); then
            log_error "$(t2 "未能找到空闲的端口跳跃范围" "Could not find a free hop range")"
            return 1
        fi
    fi
    if ! range=$(validate_hop_range "$request"); then
        log_error "$(t2 "端口跳跃范围无效，应为 起始-结束（1-65535，跨度不超过 20000）" \
            "Invalid hop range; expected START-END (1-65535, at most 20000 ports wide)"): ${1:-}"
        return 1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        log_error "$(t2 "端口跳跃需要 iptables，请先安装" "Port hopping requires iptables; install it first")"
        return 1
    fi
    if hy2_hop_range_conflicts "$range" "${CURRENT_NODE_NAME:-}"; then
        log_error "$(t2 "端口跳跃范围与其他节点的 UDP 端口或跳跃范围冲突" \
            "The hop range overlaps another node's UDP port or hop range"): $range"
        return 1
    fi
    HY2_HOP_PORTS="$range"
    log_info "$(t2 "已启用端口跳跃: UDP $range（云安全组需同步放行该范围）" \
        "Port hopping enabled: UDP $range (allow the same range in the cloud firewall)")"
}

# 采用一个 ACME 域名：校验格式、确认至少一种挑战可用，并提示 DNS 是否指向本机。
# 签发发生在 sing-box 启动之后，这里无法提前证明能签下来，只能把明显会失败的情况
# 拦在前面。
# Usage: apply_hy2_acme_domain DOMAIN [EMAIL]
apply_hy2_acme_domain() {
    local domain="${1,,}" email="${2:-}" resolved="" own4 own6
    if ! validate_tls_server_name "$domain" || [[ "$domain" != *.* || "$domain" =~ ^[0-9.]+$ ]]; then
        log_error "$(t2 "ACME 域名无效" "Invalid ACME domain"): ${1:-}"
        return 1
    fi
    if [[ -n "$email" && ! "$email" =~ ^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+$ ]]; then
        log_error "$(t2 "ACME 邮箱无效" "Invalid ACME email"): $email"
        return 1
    fi
    local alpn_ok=1 http_ok=1
    { node_tcp_port_claimed 443 || ! is_port_free 443 tcp; } && alpn_ok=0
    { node_tcp_port_claimed 80 || ! is_port_free 80 tcp; } && http_ok=0
    if (( alpn_ok == 0 && http_ok == 0 )); then
        log_error "$(t2 "ACME 签发需要 80/tcp 或 443/tcp 至少一个空闲，当前都被占用" \
            "ACME needs 80/tcp or 443/tcp to be free, and both are in use")"
        return 1
    fi
    resolved=$(getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')
    own4=$(get_ipv4)
    own6=$(get_ipv6)
    if [[ -z "$resolved" ]]; then
        log_warn "$(t2 "域名 $domain 目前无法解析，证书签发会失败，请先添加 DNS 记录" \
            "Domain $domain does not resolve yet; issuance will fail until its DNS record exists")"
    elif [[ " $resolved" != *" ${own4:-none} "* && " $resolved" != *" ${own6:-none} "* ]]; then
        log_warn "$(t2 "域名 $domain 解析到 ${resolved}，不是本机地址，证书签发可能失败" \
            "Domain $domain resolves to ${resolved}, not this server; issuance may fail")"
    fi
    HY2_DOMAIN="$domain"
    HY2_EMAIL="$email"
    log_info "$(t2 "将为 $domain 申请 ACME 证书（sing-box 启动后自动签发与续期）" \
        "An ACME certificate will be requested for $domain (issued and renewed by sing-box after start)")"
}

# 引导式选择 Hysteria2 加固方案，结果写入 HY2_REQ_OBFS / HY2_REQ_HOP /
# HY2_REQ_DOMAIN / HY2_REQ_EMAIL（取值与同名环境变量相同）。
#
# 设计目标是让用户不需要理解每个参数：前两个方案的全部参数都随机生成，回车即采用
# 推荐方案；每个方案下面写明它做什么、需要用户额外做什么。只有"自定义"才逐项提问，
# 且每一问都有可以直接回车的默认值。
prompt_hy2_hardening() {
    local choice="" answer="" hop_hint=""
    HY2_REQ_OBFS="" HY2_REQ_HOP="" HY2_REQ_DOMAIN="" HY2_REQ_EMAIL=""
    command -v iptables >/dev/null 2>&1 || \
        hop_hint="  ${RED}$(t2 "(本机没有 iptables，暂不可用)" "(unavailable: iptables is not installed)")${NC}"

    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        $(t2 "Hysteria2 加固方案（回车采用推荐）" "Hysteria2 hardening (Enter for the recommended preset)")${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    menu_note "$(t2 "Hysteria2 默认是明文特征的 QUIC + 自签名证书，握手很容易被认出来。" \
        "By default Hysteria2 is recognisable QUIC with a self-signed certificate.")" \
        "$(t2 "下面的方案会自动生成随机参数，装完直接导入链接即可使用。" \
        "The presets below generate random parameters; import the link afterwards and you are done.")"
    echo ""
    echo -e "  ${GREEN}1.${NC} $(t2 "Salamander 混淆" "Salamander obfuscation")  ${YELLOW}$(t2 "[推荐，默认]" "[recommended, default]")${NC}"
    menu_note "$(t2 "随机生成混淆密码，把流量打乱成看不出协议的数据。" \
        "Generates a random password and scrambles the traffic so the protocol is not recognisable.")" \
        "$(t2 "主流 Hysteria2 客户端都支持，密码已包含在分享链接里。" \
        "Supported by mainstream Hysteria2 clients; the password travels in the share link.")"
    echo -e "  ${GREEN}2.${NC} $(t2 "混淆 + 端口跳跃" "Obfuscation + port hopping")${hop_hint}"
    menu_note "$(t2 "在方案 1 之上，随机挑一段 200 个 UDP 端口轮换，对抗针对单个端口的限速或封锁。" \
        "On top of preset 1, rotates across a random range of 200 UDP ports against per-port throttling or blocking.")" \
        "$(t2 "需要你到云厂商安全组放行这段 UDP 端口（安装后会显示），否则会间歇断流。" \
        "You must allow that UDP range in the cloud firewall (shown after install), or connections will stall.")"
    echo -e "  ${GREEN}3.${NC} $(t2 "不加固" "No hardening")"
    menu_note "$(t2 "保持最简形态，兼容最老的客户端；被识别的风险最高。" \
        "Plain Hysteria2 for the oldest clients; the easiest to recognise.")"
    echo -e "  ${GREEN}4.${NC} $(t2 "自定义" "Custom")"
    menu_note "$(t2 "逐项选择：混淆密码、跳跃范围、用自己的域名申请真证书（ACME）。" \
        "Choose each item: obfs password, hop range, and a real certificate (ACME) for your own domain.")"
    echo ""
    echo -n "  $(t2 "请选择" "Select") [1-4] ($(t2 "默认" "default") 1): "
    } | tty_print
    tty_read choice

    case "$choice" in
        2)
            HY2_REQ_OBFS="true"
            if [[ -z "$hop_hint" ]]; then
                HY2_REQ_HOP="auto"
            else
                log_warn "$(t2 "没有 iptables，已改用方案 1（仅混淆）" "iptables is missing; using preset 1 (obfuscation only)")"
            fi
            ;;
        3) ;;
        4)
            {
            echo ""
            echo -e "  ${BLUE}$(t2 "Salamander 混淆密码" "Salamander obfs password")${NC}"
            menu_note "$(t2 "回车 = 随机生成（推荐）；输入 n = 不启用；也可以自己输入 8 位以上的密码。" \
                "Enter = random (recommended); n = off; or type your own password of 8+ characters.")"
            echo -n "  > "
            } | tty_print
            tty_read answer
            case "${answer,,}" in
                "") HY2_REQ_OBFS="true" ;;
                n|no) HY2_REQ_OBFS="" ;;
                *) HY2_REQ_OBFS="$answer" ;;
            esac
            {
            echo ""
            echo -e "  ${BLUE}$(t2 "端口跳跃范围" "Port hopping range")${NC}${hop_hint}"
            menu_note "$(t2 "回车 = 不启用；输入 a = 随机挑一段（推荐）；或输入 起始-结束，例如 20000-20200。" \
                "Enter = off; a = pick a random range (recommended); or START-END such as 20000-20200.")"
            echo -n "  > "
            } | tty_print
            tty_read answer
            case "${answer,,}" in
                "") HY2_REQ_HOP="" ;;
                a|auto) HY2_REQ_HOP="auto" ;;
                *) HY2_REQ_HOP="$answer" ;;
            esac
            {
            echo ""
            echo -e "  ${BLUE}$(t2 "ACME 证书域名" "ACME certificate domain")${NC}"
            menu_note "$(t2 "回车 = 用自签名证书（无需域名）。" "Enter = keep the self-signed certificate (no domain needed).")" \
                "$(t2 "有域名且已解析到本机时填在这里，客户端就不再需要 insecure；需要 80 或 443/tcp 空闲。" \
                "If you own a domain that already points here, type it: clients no longer need insecure. Needs 80 or 443/tcp free.")"
            echo -n "  > "
            } | tty_print
            tty_read answer
            HY2_REQ_DOMAIN="$answer"
            ;;
        *) HY2_REQ_OBFS="true" ;;
    esac
}

# 为当前正在安装的 Hysteria2 节点应用可选加固。
#   hy2obfs=true|<password>  Salamander 混淆（true 为随机密码）
#   hy2hop=auto|20000-20100  端口跳跃：把这段 UDP 端口重定向到监听端口（auto 随机选段）
#   hy2domain=example.com    用 ACME 为该域名签发真证书，替代自签名证书（hy2email 可选）
#
# 两条入口：完全交互的安装走引导菜单（默认采用推荐方案）；只要调用方用 proto= 或
# 任一 hy2* 变量驱动安装，就只按环境变量执行、不追加提问，默认全部关闭——既有的
# 无人值守脚本因此得到与升级前完全相同的节点。
configure_hy2_options() {
    HY2_OBFS_PASSWORD=""
    HY2_HOP_PORTS=""
    HY2_DOMAIN=""
    HY2_EMAIL=""

    HY2_REQ_OBFS="${hy2obfs:-}"
    HY2_REQ_HOP="${hy2hop:-}"
    HY2_REQ_DOMAIN="${hy2domain:-}"
    HY2_REQ_EMAIL="${hy2email:-}"
    if [[ -z "${proto:-}${hy2obfs:-}${hy2hop:-}${hy2domain:-}" ]] && tty_available; then
        prompt_hy2_hardening
    fi

    if [[ -n "$HY2_REQ_DOMAIN" ]]; then
        apply_hy2_acme_domain "$HY2_REQ_DOMAIN" "$HY2_REQ_EMAIL" || return 1
    fi

    if [[ -n "$HY2_REQ_HOP" ]]; then
        apply_hy2_hop_range "$HY2_REQ_HOP" || return 1
    fi

    local obfs_request="$HY2_REQ_OBFS"
    case "${obfs_request,,}" in
        ""|false|0|n|no|off) ;;
        true|1|y|yes|on)
            HY2_OBFS_PASSWORD=$(openssl rand -hex 16)
            ;;
        *)
            if [[ ! "$obfs_request" =~ ^[a-zA-Z0-9._-]{8,128}$ ]]; then
                log_error "$(t2 "hy2obfs 密码需为 8-128 位字母、数字或 ._-" \
                    "hy2obfs password must be 8-128 characters of letters, digits or ._-")"
                return 1
            fi
            HY2_OBFS_PASSWORD="$obfs_request"
            ;;
    esac
    if [[ -n "$HY2_OBFS_PASSWORD" ]]; then
        log_info "$(t2 "已启用 Salamander 混淆（密码已写入分享链接，客户端导入即可）" \
            "Salamander obfuscation enabled (the password is in the share link; just import it)")"
    fi
}

# ============== sing-box Release 管理 ==============
#
# 目标与 Xray 的 release 管理一致：没有通过官方 SHA-256 的归档不会被执行，替换失败
# 能回到旧 binary。实现刻意比 Xray 的事务轻：sing-box 只是一个由本脚本独占管理的
# binary，这里用"同目录暂存 + rename 原子替换 + 带版本号的备份"覆盖下载损坏、候选
# 不可执行、新版本拒绝现有配置、替换后服务起不来这四类失败。
#
# SHA-256 来自 GitHub release API 中每个资产的 digest 字段（"sha256:<hex>"）。
# 该字段缺失或格式不符时失败关闭；确需安装这样的 release 时，由操作者用
# SINGBOX_SHA256=<hex> 明确给出期望值，脚本仍然按它校验。
SINGBOX_RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases"
SINGBOX_MAX_ARCHIVE_BYTES=$((300 * 1024 * 1024))
# 低于该版本的 sing-box 缺少 AnyTLS 默认不再上传客户端元数据的修正（1.13.16）。
SINGBOX_BASELINE_VERSION="1.13.16"

# 请求的固定版本（SINGBOX_VERSION / singbox_version，可带 v 前缀）；未指定输出空串。
singbox_requested_version() {
    local raw="${SINGBOX_VERSION:-${singbox_version:-}}"
    [[ -z "$raw" ]] && return 0
    raw="${raw#v}"
    [[ "$raw" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9._-]+)?$ ]] || return 1
    printf '%s' "$raw"
}

map_singbox_arch() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64)   printf '%s' amd64 ;;
        aarch64|arm64)  printf '%s' arm64 ;;
        armv7l|armv7)   printf '%s' armv7 ;;
        i686|i386)      printf '%s' 386 ;;
        *) return 1 ;;
    esac
}

# 取 release 元数据（JSON）。Usage: singbox_release_json [VERSION]（缺省为 latest stable）
singbox_release_json() {
    local version="${1:-}" url="$SINGBOX_RELEASE_API/latest"
    [[ -n "$version" ]] && url="$SINGBOX_RELEASE_API/tags/v${version}"
    secure_curl "$url" 2>/dev/null
}

# 从 release JSON 里选出本机应使用的归档，输出一行 "NAME URL SHA256"。
# musl 主机优先 "-musl" 静态归档；没有它的旧 release 回落到默认归档（1.13 之前的
# 默认归档本身是静态链接的）。
# Usage: singbox_select_asset RELEASE_JSON VERSION ARCH
singbox_select_asset() {
    local json="$1" version="$2" arch="$3" name row digest
    local -a names=()
    system_is_musl && names+=("sing-box-${version}-linux-${arch}-musl.tar.gz")
    names+=("sing-box-${version}-linux-${arch}.tar.gz")
    for name in "${names[@]}"; do
        row=$(jq -r --arg name "$name" \
            '.assets[]? | select(.name == $name) | "\(.browser_download_url) \(.digest // "")"' \
            <<<"$json" 2>/dev/null | head -n 1)
        [[ -n "$row" ]] || continue
        digest="${row#* }"
        [[ "${row%% *}" == https://github.com/SagerNet/sing-box/releases/download/* ]] || return 1
        if [[ -n "${SINGBOX_SHA256:-}" ]]; then
            digest="sha256:${SINGBOX_SHA256,,}"
        fi
        if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            log_error "$(t2 "release 元数据没有 $name 的 SHA-256，拒绝安装未校验的归档（可用 SINGBOX_SHA256=<hex> 明确指定）" \
                "The release metadata has no SHA-256 for $name; refusing an unverified archive (set SINGBOX_SHA256=<hex> to supply one)")"
            return 1
        fi
        printf '%s %s %s\n' "$name" "${row%% *}" "${digest#sha256:}"
        return 0
    done
    log_error "No sing-box archive for linux-${arch} in release v${version}"
    return 1
}

# 下载、校验并解出候选 binary，输出其路径。
# Usage: singbox_fetch_candidate WORK_DIR NAME URL SHA256 VERSION
singbox_fetch_candidate() {
    local work="$1" name="$2" url="$3" expected="$4" version="$5" archive actual size candidate reported
    archive="$work/$name"
    if ! secure_curl "$url" -o "$archive"; then
        log_error "Failed to download $name"
        return 1
    fi
    size=$(stat -c '%s' "$archive" 2>/dev/null) || return 1
    (( size > 0 && size <= SINGBOX_MAX_ARCHIVE_BYTES )) || { log_error "Unexpected archive size: $size"; return 1; }
    actual=$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "$(t2 "sing-box 归档 SHA-256 不匹配，已丢弃" "sing-box archive SHA-256 mismatch; discarded") (expected $expected, got ${actual:-none})"
        return 1
    fi
    mkdir -p -- "$work/unpacked" || return 1
    if ! tar -xzf "$archive" -C "$work/unpacked" --no-same-owner 2>/dev/null; then
        log_error "Failed to extract sing-box archive"
        return 1
    fi
    candidate=$(find "$work/unpacked" -type f -name sing-box 2>/dev/null | head -n 1)
    if [[ -z "$candidate" ]]; then
        log_error "sing-box binary not found in archive"
        return 1
    fi
    chmod 755 "$candidate" || return 1
    # 立刻验证可执行性与版本：不兼容的 binary（例如 musl 主机拿到 glibc 构建）要在
    # 这里失败，而不是等到 config check 才被报成"配置无效"。
    if ! reported=$(timeout 20 "$candidate" version 2>/dev/null </dev/null); then
        log_error "Installed sing-box binary cannot be executed on this system"
        system_is_musl && log_error "This system uses musl libc; no compatible sing-box build was found for v${version}"
        return 1
    fi
    if [[ ! "$reported" =~ sing-box[[:space:]]+version[[:space:]]+${version//./\\.}([[:space:]]|$) ]]; then
        log_error "Downloaded sing-box does not report version $version"
        return 1
    fi
    printf '%s\n' "$candidate"
}

# 只保留最近 SINGBOX_BACKUP_KEEP（默认 3）份脚本创建的备份。
singbox_prune_backups() {
    local keep="${SINGBOX_BACKUP_KEEP:-3}" backup index=0
    [[ "$keep" =~ ^[0-9]{1,3}$ ]] || keep=3
    while IFS= read -r backup; do
        index=$((index + 1))
        (( index > keep )) && rm -f -- "$backup"
    done < <(ls -1t -- "${SINGBOX_BIN}".bak-v*-[0-9]*-[0-9]* 2>/dev/null)
    return 0
}

# 安装或更新 sing-box。
# Usage: singbox_install_release fresh|update
#   fresh   全新安装（install_singbox 调用）；不重启服务
#   update  替换已有 binary：新 binary 必须接受现有配置；原先在运行则重启并确认 active，
#           任一步失败都恢复旧 binary 与原服务状态
singbox_install_release() {
    local intent="${1:-update}" version arch json asset name url digest work candidate
    local old_version="" backup="" stage was_active=0 rc=0

    if ! version=$(singbox_requested_version); then
        log_error "Invalid SINGBOX_VERSION: ${SINGBOX_VERSION:-${singbox_version:-}}"
        return 1
    fi
    arch=$(map_singbox_arch) || { log_error "Unsupported architecture for sing-box: $(uname -m)"; return 1; }
    json=$(singbox_release_json "$version") || json=""
    if [[ -z "$version" ]]; then
        version=$(jq -r '.tag_name // empty' <<<"$json" 2>/dev/null)
        version="${version#v}"
    fi
    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9._-]+)?$ ]]; then
        log_error "Failed to get sing-box release metadata"
        return 1
    fi

    old_version=$(singbox_installed_version) || old_version=""
    if [[ "$intent" == "update" && -n "$old_version" && "$old_version" == "$version" \
        && -z "${SINGBOX_VERSION:-${singbox_version:-}}" ]]; then
        log_info "$(t2 "sing-box 已是最新版本" "sing-box is already up to date"): v$version"
        return 0
    fi
    if [[ "$intent" == "update" && -n "$old_version" && -z "${SINGBOX_VERSION:-${singbox_version:-}}" ]] \
        && ! version_ge "$version" "$old_version"; then
        log_warn "$(t2 "已安装的 sing-box 比 stable 更新，不自动降级" "Installed sing-box is newer than stable; refusing an automatic downgrade"): v$old_version > v$version"
        return 0
    fi

    asset=$(singbox_select_asset "$json" "$version" "$arch") || return 1
    read -r name url digest <<<"$asset"
    system_is_musl && [[ "$name" == *-musl.tar.gz ]] && \
        log_info "musl libc detected, using the statically linked sing-box build"
    log_info "Installing sing-box v${version} (${arch})..."

    work=$(mktemp -d) || return 1
    candidate=$(singbox_fetch_candidate "$work" "$name" "$url" "$digest" "$version") || { rm -rf -- "$work"; return 1; }

    # 新 binary 必须接受现有配置，否则替换后服务必然起不来。
    if [[ -s "$SINGBOX_CONF" ]] && ! "$candidate" check -c "$SINGBOX_CONF" >/dev/null 2>&1; then
        log_error "$(t2 "新版 sing-box 不接受现有配置，已取消更新（现有 binary 未改动）" \
            "The new sing-box rejects the current config; update cancelled (existing binary untouched)")"
        rm -rf -- "$work"
        return 1
    fi

    mkdir -p "$SINGBOX_DIR" "$(dirname "$SINGBOX_BIN")" || { rm -rf -- "$work"; return 1; }
    stage=$(mktemp "$(dirname "$SINGBOX_BIN")/.sing-box.new.XXXXXXXX") || { rm -rf -- "$work"; return 1; }
    if ! cp -- "$candidate" "$stage" || ! chmod 755 "$stage"; then
        rm -rf -- "$work" "$stage"
        return 1
    fi
    rm -rf -- "$work"

    if [[ -f "$SINGBOX_BIN" ]]; then
        backup="${SINGBOX_BIN}.bak-v${old_version:-unknown}-$(date +%Y%m%d-%H%M%S)"
        cp -p -- "$SINGBOX_BIN" "$backup" || { rm -f -- "$stage"; return 1; }
        service_is_active "$SINGBOX_SERVICE" && was_active=1
    fi
    # rename 在同一目录内是原子的：任何时刻该路径上要么是旧 binary，要么是新 binary。
    mv -f -- "$stage" "$SINGBOX_BIN" || { rm -f -- "$stage"; return 1; }

    if (( was_active == 1 )); then
        service_restart "$SINGBOX_SERVICE" || rc=1
        sleep 1
        service_is_active "$SINGBOX_SERVICE" || rc=1
        if (( rc != 0 )); then
            log_error "$(t2 "新版 sing-box 启动失败，正在恢复旧版本" "The new sing-box failed to start; restoring the previous version")"
            cp -p -- "$backup" "${SINGBOX_BIN}.restore" && mv -f -- "${SINGBOX_BIN}.restore" "$SINGBOX_BIN"
            service_restart "$SINGBOX_SERVICE" || true
            return 1
        fi
    fi

    singbox_prune_backups
    log_info "sing-box v${version} installed successfully"
    return 0
}

# 只读显示 sing-box 的本地版本、latest stable 与安全基线。远端查询失败只把该项标为
# 不可用，本地结果照常显示。
cmd_singbox_version() {
    local installed latest="" json relation=""
    installed=$(singbox_installed_version) || installed=""
    json=$(singbox_release_json "") || json=""
    latest=$(jq -r '.tag_name // empty' <<<"$json" 2>/dev/null) || latest=""
    latest="${latest#v}"

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     sing-box $(t2 "版本" "version")${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  $(t2 "已安装" "Installed"):      ${YELLOW}${installed:+v}${installed:-$(t2 "未安装" "Not installed")}${NC}"
    echo -e "  Latest stable:  ${YELLOW}${latest:+v}${latest:-$(t2 "查询失败" "unavailable")}${NC}"
    echo -e "  $(t2 "安全基线" "Security baseline"): v${SINGBOX_BASELINE_VERSION}"
    if [[ -n "$installed" ]]; then
        if ! version_ge "$installed" "$SINGBOX_BASELINE_VERSION"; then
            relation="${RED}$(t2 "低于安全基线，建议立即更新" "below the security baseline; update now")${NC}"
        elif [[ -n "$latest" ]] && ! version_ge "$installed" "$latest"; then
            relation="${YELLOW}$(t2 "有新版本可用" "an update is available")${NC}"
        elif [[ -n "$latest" ]]; then
            relation="${GREEN}$(t2 "已是最新" "up to date")${NC}"
        fi
        [[ -n "$relation" ]] && echo -e "  $(t2 "状态" "Status"):        $relation"
    fi
    echo ""
}

# 更新 sing-box 到 latest stable，或 SINGBOX_VERSION 指定的版本。
cmd_singbox_update() {
    if ! is_root; then
        log_error "$(msg run_as_root)"
        return 1
    fi
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        log_error "$(t2 "sing-box 尚未安装；添加 AnyTLS 或 Hysteria2 节点时会自动安装" \
            "sing-box is not installed; it is installed automatically with the first AnyTLS or Hysteria2 node")"
        return 1
    fi
    singbox_install_release update
}

# 工具菜单入口：先显示状态，再确认是否更新。
cmd_singbox_release_menu() {
    local answer=""
    cmd_singbox_version
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        read -rp "$(msg menu_press_enter)"
        return 0
    fi
    menu_note "$(t2 "更新会校验官方 SHA-256，并先用新版本检查现有配置；启动失败自动回滚旧版本。" \
        "An update verifies the official SHA-256 and checks the current config with the new version; a failed start rolls back.")"
    echo ""
    echo -n "  $(t2 "更新到 latest stable?" "Update to the latest stable?") [y/N]: "
    read -r answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        cmd_singbox_update || true
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== WARP 管理 ==============

cmd_warp() {
    while true; do
        clear
        local warp_status
        if check_warp_running; then
            warp_status="${GREEN}$(msg warp_running)${NC}"
        else
            warp_status="${RED}$(msg warp_stopped)${NC}"
        fi

        local netflix_status ai_status
        if [[ -f "/root/.warp_netflix" ]]; then
            netflix_status="${GREEN}ON${NC}"
        else
            netflix_status="${YELLOW}OFF${NC}"
        fi
        if [[ -f "/root/.warp_ai" ]]; then
            ai_status="${GREEN}ON${NC}"
        else
            ai_status="${YELLOW}OFF${NC}"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_warp)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg warp_status): $warp_status"
        echo ""
        echo -e "  ${GREEN}1.${NC} $(msg warp_install)"
        echo -e "  ${GREEN}2.${NC} $(msg warp_uninstall)"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}3.${NC} $(msg warp_netflix) [$netflix_status]"
        echo -e "  ${GREEN}4.${NC} $(msg warp_ai) [$ai_status]"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-4]: "
        read -r choice

        case "$choice" in
            1) warp_install ;;
            2) warp_uninstall ;;
            3) warp_toggle_netflix ;;
            4) warp_toggle_ai ;;
            0) return ;;
            *) ;;
        esac
    done
}

warp_install() {
    echo ""
    log_info "Installing WARP (Socks5 mode)..."
    # Security: Download to temp file with secure options
    local tmp_warp="/tmp/warp-menu-$$.sh"
    if secure_curl "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" -o "$tmp_warp" 2>/dev/null; then
        bash "$tmp_warp" c
        rm -f "$tmp_warp"
        if check_warp_running; then
            log_info "WARP installed successfully"
            write_config
            service_restart xray
        fi
    else
        log_error "Failed to download WARP installer"
        rm -f "$tmp_warp"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_uninstall() {
    echo ""
    log_info "Uninstalling WARP..."
    if command -v warp &>/dev/null; then
        warp u
    elif [[ -f menu.sh ]]; then
        bash menu.sh u
    else
        # Security: Download to temp file with secure options
        local tmp_warp="/tmp/warp-menu-$$.sh"
        if secure_curl "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" -o "$tmp_warp" 2>/dev/null; then
            bash "$tmp_warp" u
            rm -f "$tmp_warp"
        fi
    fi
    rm -f /root/.warp_netflix /root/.warp_ai
    write_config
    service_restart xray
    log_info "WARP uninstalled"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_toggle_netflix() {
    if ! check_warp_running; then
        log_warn "WARP is not running. Please install first."
        sleep 2
        return
    fi
    if [[ -f "/root/.warp_netflix" ]]; then
        rm -f /root/.warp_netflix
        log_info "Netflix routing disabled"
    else
        # 分流规则使用 geosite:netflix，需要 GeoSite 数据库
        ensure_geodata
        touch /root/.warp_netflix
        log_info "Netflix routing enabled"
    fi
    write_config
    service_restart xray
    echo ""
    read -rp "$(msg menu_press_enter)"
}

warp_toggle_ai() {
    if ! check_warp_running; then
        log_warn "WARP is not running. Please install first."
        sleep 2
        return
    fi
    if [[ -f "/root/.warp_ai" ]]; then
        rm -f /root/.warp_ai
        log_info "AI services routing disabled"
    else
        # 分流规则使用 geosite:openai/anthropic，需要 GeoSite 数据库
        ensure_geodata
        touch /root/.warp_ai
        log_info "AI services routing enabled"
    fi
    write_config
    service_restart xray
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== BBR 管理 ==============

cmd_bbr() {
    while true; do
        clear
        local bbr_status qdisc_status
        local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)

        if [[ "$cc" == "bbr" ]]; then
            bbr_status="${GREEN}$(msg bbr_enabled)${NC} (BBR)"
        else
            bbr_status="${YELLOW}$(msg bbr_disabled)${NC} ($cc)"
        fi
        qdisc_status="$qd"

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_bbr)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Congestion Control: $bbr_status"
        echo -e "  Queue Discipline: ${YELLOW}$qdisc_status${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Enable BBR + FQ"
        echo -e "  ${GREEN}2.${NC} Disable BBR (use CUBIC)"
        echo -e "  ${GREEN}3.${NC} Apply TCP optimization"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-3]: "
        read -r choice

        case "$choice" in
            1) bbr_enable ;;
            2) bbr_disable ;;
            3) bbr_optimize ;;
            0) return ;;
            *) ;;
        esac
    done
}

bbr_enable() {
    echo ""
    log_info "Enabling BBR..."
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1
    log_info "BBR enabled"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

bbr_disable() {
    echo ""
    log_info "Disabling BBR..."
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic
EOF
    sysctl --system >/dev/null 2>&1
    log_info "BBR disabled, using CUBIC"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

bbr_optimize() {
    echo ""
    log_info "Applying TCP optimization..."
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = $qd
net.ipv4.tcp_congestion_control = $cc
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system >/dev/null 2>&1
    log_info "TCP optimization applied"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== Swap 管理 ==============

cmd_swap() {
    while true; do
        clear
        local swap_total swap_status swappiness
        swap_total=$(free -m | grep Swap | awk '{print $2}')
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")

        if [[ "$swap_total" -eq 0 ]]; then
            swap_status="${RED}Not enabled${NC}"
        else
            swap_status="${GREEN}${swap_total}MB${NC}"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_swap)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg swap_size): $swap_status"
        echo -e "  Swappiness: ${YELLOW}$swappiness${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Create/Resize Swap"
        echo -e "  ${GREEN}2.${NC} Remove Swap"
        echo -e "  ${GREEN}3.${NC} Change Swappiness"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-3]: "
        read -r choice

        case "$choice" in
            1) swap_create ;;
            2) swap_remove ;;
            3) swap_swappiness ;;
            0) return ;;
            *) ;;
        esac
    done
}

swap_create() {
    echo ""
    echo -n "  Enter swap size in MB [1024]: "
    read -r size
    size=${size:-1024}

    log_info "Creating ${size}MB swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile

    if ! fallocate -l ${size}M /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=$size status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log_info "Swap created: ${size}MB"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

swap_remove() {
    echo ""
    log_info "Removing swap..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
    log_info "Swap removed"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

swap_swappiness() {
    echo ""
    local current=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
    echo -e "  Current swappiness: ${YELLOW}$current${NC}"
    echo -n "  Enter new value [0-100]: "
    read -r val
    if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 0 ]] && [[ "$val" -le 100 ]]; then
        sysctl -w vm.swappiness=$val >/dev/null
        sed -i '/vm.swappiness/d' /etc/sysctl.conf 2>/dev/null || true
        echo "vm.swappiness = $val" >> /etc/sysctl.conf
        log_info "Swappiness set to $val"
    else
        log_error "Invalid value"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# ============== Fail2ban 管理 ==============

cmd_fail2ban() {
    # 检查是否是 Alpine (不支持 fail2ban)
    if [[ "$PKG_MANAGER" == "apk" ]]; then
        log_warn "Fail2ban is not available on Alpine Linux"
        sleep 2
        return
    fi

    while true; do
        clear
        local f2b_status banned_count

        if systemctl is-active fail2ban &>/dev/null; then
            f2b_status="${GREEN}Running${NC}"
            banned_count=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | grep -o "[0-9]*" || echo "0")
        else
            f2b_status="${RED}Stopped${NC}"
            banned_count="N/A"
        fi

        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg menu_fail2ban)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  $(msg fail2ban_status): $f2b_status"
        echo -e "  Banned IPs: ${RED}$banned_count${NC}"
        echo ""
        echo -e "  ${GREEN}1.${NC} Install & Enable Fail2ban"
        echo -e "  ${GREEN}2.${NC} Stop Fail2ban"
        echo -e "  ${GREEN}3.${NC} View Banned IPs"
        echo -e "  ${GREEN}4.${NC} Unban IP"
        echo -e "  ${GREEN}5.${NC} View Logs"
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${RED}0.${NC} Back / 返回"
        echo ""
        echo -n "  $(msg menu_choice) [0-5]: "
        read -r choice

        case "$choice" in
            1) fail2ban_install ;;
            2) fail2ban_stop ;;
            3) fail2ban_list ;;
            4) fail2ban_unban ;;
            5) fail2ban_logs ;;
            0) return ;;
            *) ;;
        esac
    done
}

fail2ban_install() {
    echo ""
    log_info "Installing Fail2ban..."

    if ! $PKG_CHECK fail2ban >/dev/null 2>&1; then
        $PKG_UPDATE >/dev/null 2>&1 || true
        $PKG_INSTALL fail2ban >/dev/null 2>&1
    fi

    # 获取当前 SSH 端口
    local ssh_port
    ssh_port=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | head -1 | awk '{print $2}')
    ssh_port=${ssh_port:-22}

    # 配置 jail
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1d
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 30d
findtime = 7d
maxretry = 3
backend = auto

[sshd]
enabled = true
port = $ssh_port,22
mode = aggressive
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    log_info "Fail2ban installed and configured"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_stop() {
    echo ""
    systemctl stop fail2ban 2>/dev/null
    systemctl disable fail2ban 2>/dev/null
    log_info "Fail2ban stopped"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_list() {
    echo ""
    echo -e "${CYAN}Banned IPs:${NC}"
    fail2ban-client status sshd 2>/dev/null | grep "Banned IP" || echo "  None"
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_unban() {
    echo ""
    echo -n "  Enter IP to unban: "
    read -r ip
    if [[ -n "$ip" ]]; then
        fail2ban-client set sshd unbanip "$ip" 2>/dev/null && log_info "Unbanned: $ip" || log_error "Failed to unban"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

fail2ban_logs() {
    echo ""
    echo -e "${CYAN}Recent Fail2ban logs:${NC}"
    if [[ -f /var/log/fail2ban.log ]]; then
        grep -E "(Ban|Unban)" /var/log/fail2ban.log 2>/dev/null | tail -20
    else
        echo "  No logs available"
    fi
    echo ""
    read -rp "$(msg menu_press_enter)"
}

# 选择协议类型
prompt_protocol_type() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     选择节点协议类型${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} VLESS + Vision + REALITY  ${GRAY}(TCP 传输, 推荐)${NC}"
    echo -e "  ${GREEN}2.${NC} VLESS + XHTTP + REALITY   ${GRAY}(XHTTP 传输)${NC}"
    echo -e "  ${GREEN}3.${NC} 两个都安装               ${GRAY}(生成两个端口)${NC}"
    echo -e "  ${GREEN}4.${NC} Shadowsocks 2022         ${GRAY}(SS 协议, 高性能)${NC}"
    echo -e "  ${GREEN}5.${NC} AnyTLS                   ${GRAY}(sing-box, 自签名证书)${NC}"
    echo -e "  ${GREEN}6.${NC} AnyTLS + REALITY         ${GRAY}(sing-box, 抗封锁, 推荐)${NC}"
    echo ""
    echo -n "  请选择 [1-6] (默认 1): "
    } >/dev/tty

    local choice
    read -r choice </dev/tty

    case "$choice" in
        2)
            PROTOCOL_TYPE="xhttp"
            log_info "已选择: VLESS + XHTTP + REALITY"
            ;;
        3)
            PROTOCOL_TYPE="both"
            log_info "已选择: Vision + XHTTP 双协议"
            ;;
        4)
            PROTOCOL_TYPE="shadowsocks"
            log_info "已选择: Shadowsocks 2022"
            ;;
        5)
            PROTOCOL_TYPE="anytls"
            log_info "已选择: AnyTLS"
            ;;
        6)
            PROTOCOL_TYPE="anytls_reality"
            log_info "已选择: AnyTLS + REALITY"
            ;;
        *)
            PROTOCOL_TYPE="vision"
            log_info "已选择: VLESS + Vision + REALITY"
            ;;
    esac
}

# 选择 Shadowsocks 加密方式
prompt_ss_method() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                  Shadowsocks 加密方式${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}推荐 (2022 协议, 更安全):${NC}"
    echo -e "  ${GREEN}1.${NC} 2022-blake3-aes-256-gcm      ${GRAY}(推荐, 硬件加速)${NC}"
    echo -e "  ${GREEN}2.${NC} 2022-blake3-chacha20-poly1305 ${GRAY}(移动设备优化)${NC}"
    echo ""
    echo -e "  ${YELLOW}传统方式 (兼容性更好):${NC}"
    echo -e "  ${GREEN}3.${NC} chacha20-ietf-poly1305       ${GRAY}(广泛支持)${NC}"
    echo -e "  ${GREEN}4.${NC} aes-256-gcm                  ${GRAY}(经典加密)${NC}"
    echo ""
    echo -n "  请选择 [1-4] (默认 1): "
    } >/dev/tty

    local choice
    read -r choice </dev/tty

    case "$choice" in
        2)
            SS_METHOD="2022-blake3-chacha20-poly1305"
            ;;
        3)
            SS_METHOD="chacha20-ietf-poly1305"
            ;;
        4)
            SS_METHOD="aes-256-gcm"
            ;;
        *)
            SS_METHOD="2022-blake3-aes-256-gcm"
            ;;
    esac
    log_info "加密方式: $SS_METHOD"
}

# 生成 Shadowsocks 密码/密钥
gen_ss_password() {
    # 2022 协议需要 base64 编码的预共享密钥
    # 2022-blake3-aes-256-gcm 和 2022-blake3-chacha20-poly1305 需要 32 字节
    # 传统方式使用随机字符串密码
    case "$SS_METHOD" in
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            SS_PASSWORD=$(openssl rand -base64 32)
            ;;
        2022-blake3-aes-128-gcm)
            SS_PASSWORD=$(openssl rand -base64 16)
            ;;
        *)
            # 传统方式：生成 16 字符随机密码
            SS_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            ;;
    esac
    log_info "密码已生成"
}

gen_uuid() {
    UUID="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
}

# 生成一个可用的随机端口
gen_random_free_port() {
    local exclude_port="${1:-0}"
    local port
    while true; do
        port="$(shuf -i ${PORT_MIN}-${PORT_MAX} -n 1)"
        if is_port_free "$port" && [[ "$port" != "$exclude_port" ]]; then
            echo "$port"
            return 0
        fi
    done
}

# 交互式选择端口
# Usage: prompt_port "提示信息" "默认端口" "排除端口(可选)"
prompt_port() {
    local prompt_msg="$1"
    local default_port="$2"
    local exclude_port="${3:-0}"
    local user_port

    while true; do
        echo -n "  $prompt_msg [默认: $default_port]: " >/dev/tty
        read -r user_port </dev/tty

        # 用户直接回车，使用默认端口
        if [[ -z "$user_port" ]]; then
            echo "$default_port"
            return 0
        fi

        # 验证端口格式
        if ! [[ "$user_port" =~ ^[0-9]+$ ]]; then
            echo -e "  ${RED}端口必须是数字${NC}" >/dev/tty
            continue
        fi

        # 验证端口范围
        if [[ "$user_port" -lt 1 || "$user_port" -gt 65535 ]]; then
            echo -e "  ${RED}端口必须在 1-65535 之间${NC}" >/dev/tty
            continue
        fi

        # 检查是否与排除端口冲突
        if [[ "$user_port" == "$exclude_port" ]]; then
            echo -e "  ${RED}端口不能与其他服务端口相同${NC}" >/dev/tty
            continue
        fi

        # 检查端口是否被占用
        if ! is_port_free "$user_port"; then
            echo -e "  ${YELLOW}端口 $user_port 已被占用，是否仍然使用? [y/N]: ${NC}" >/dev/tty
            read -r confirm </dev/tty
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                echo "$user_port"
                return 0
            fi
            continue
        fi

        echo "$user_port"
        return 0
    done
}

# 选择端口（根据协议类型）
choose_ports() {
    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                     端口配置${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    } >/dev/tty

    # Shadowsocks 端口
    if [[ "$PROTOCOL_TYPE" == "shadowsocks" ]]; then
        if [[ -n "${sspt:-}" ]]; then
            # 环境变量指定
            PORT="$sspt"
        elif [[ -n "${vlpt:-}" ]]; then
            # 兼容 vlpt 变量
            PORT="$vlpt"
        else
            # 交互式选择
            local default_ss_port
            default_ss_port=$(gen_random_free_port)
            PORT=$(prompt_port "Shadowsocks 端口" "$default_ss_port")
        fi
        log_info "Shadowsocks 端口: $PORT"
        XHTTP_PORT=""
        XHTTP_PATH=""
        echo "" >/dev/tty
        return 0
    fi

    # AnyTLS 端口
    if [[ "$PROTOCOL_TYPE" == "anytls" || "$PROTOCOL_TYPE" == "anytls_reality" ]]; then
        if [[ -n "${atpt:-}" ]]; then
            PORT="$atpt"
        elif [[ -n "${vlpt:-}" ]]; then
            PORT="$vlpt"
        else
            local default_at_port
            default_at_port=$(gen_random_free_port)
            PORT=$(prompt_port "AnyTLS 端口" "$default_at_port")
        fi
        log_info "AnyTLS 端口: $PORT"
        XHTTP_PORT=""
        XHTTP_PATH=""
        echo "" >/dev/tty
        return 0
    fi

    # Vision 端口（如果需要）
    if [[ "$PROTOCOL_TYPE" == "vision" || "$PROTOCOL_TYPE" == "both" ]]; then
        if [[ -n "${vlpt:-}" ]]; then
            # 环境变量指定，直接使用
            PORT="$vlpt"
        else
            # 交互式选择
            local default_vision_port
            default_vision_port=$(gen_random_free_port)
            PORT=$(prompt_port "Vision 端口" "$default_vision_port")
        fi
        log_info "Vision 端口: $PORT"
    else
        PORT=""
    fi

    # XHTTP 端口（如果需要）
    if [[ "$PROTOCOL_TYPE" == "xhttp" || "$PROTOCOL_TYPE" == "both" ]]; then
        if [[ -n "${xhpt:-}" ]]; then
            # 环境变量指定，直接使用
            XHTTP_PORT="$xhpt"
        else
            # 交互式选择（排除 Vision 端口）
            local default_xhttp_port
            default_xhttp_port=$(gen_random_free_port "${PORT:-0}")
            XHTTP_PORT=$(prompt_port "XHTTP 端口" "$default_xhttp_port" "${PORT:-0}")
        fi
        XHTTP_PATH="/$(openssl rand -hex 4)"
        log_info "XHTTP 端口: $XHTTP_PORT, 路径: $XHTTP_PATH"
    else
        XHTTP_PORT=""
        XHTTP_PATH=""
    fi

    echo "" >/dev/tty
}

gen_reality_keys() {
    log_info "$(msg gen_keys)"
    local KEYS
    # tr -d '\r' 防止部分内核输出 CRLF 行尾导致密钥末尾混入 \r,
    # 进而被 safe_read_config_value 的字符白名单判定为 "unsafe value".
    # 优先使用已安装的 xray (x25519)，否则回退到 sing-box (generate reality-keypair)。
    # 两者输出的 X25519 密钥格式互相兼容，AnyTLS 节点因此无需安装 xray。
    if [[ -x "$XRAY_BIN" ]]; then
        KEYS="$("$XRAY_BIN" x25519 | tr -d '\r')"
    elif [[ -x "$SINGBOX_BIN" ]]; then
        KEYS="$("$SINGBOX_BIN" generate reality-keypair | tr -d '\r')"
    else
        log_error "需要 xray 或 sing-box 来生成 REALITY 密钥"
        return 1
    fi

    # 提取私钥. 兼容多种 xray 版本输出标签:
    #   "PrivateKey: xxx"          (现代版本)
    #   "Private key: xxx"         (旧版本)
    #   "PrivateKey (Private): xxx" (新版本带括号备注)
    # 不依赖字段切分, 直接取第一个 ':' 之后的内容并裁剪空白.
    PRIVATE_KEY="$(echo "$KEYS" | awk '
        /^(PrivateKey|Private[[:space:]]+key)([[:space:]]*\([^)]*\))?[[:space:]]*:/ {
            idx = index($0, ":")
            val = substr($0, idx + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val
            exit
        }
    ')"

    # 提取公钥. 兼容多种 xray 版本输出标签:
    #   "Password: xxx"            (中期版本)
    #   "PublicKey: xxx"           (现代版本)
    #   "Public key: xxx"          (旧版本)
    #   "Password (PublicKey): xxx" (最新版本带括号备注)
    PUBLIC_KEY="$(echo "$KEYS" | awk '
        /^(Password|PublicKey|Public[[:space:]]+key)([[:space:]]*\([^)]*\))?[[:space:]]*:/ {
            idx = index($0, ":")
            val = substr($0, idx + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val
            exit
        }
    ')"

    SHORT_ID="$(openssl rand -hex 4)"

    # 验证密钥
    if [[ -z "$PRIVATE_KEY" ]]; then
        log_error "Failed to extract private key"
        log_error "Xray output: $KEYS"
        return 1
    fi

    if [[ -z "$PUBLIC_KEY" ]]; then
        log_error "Failed to extract public key"
        log_error "Xray output: $KEYS"
        return 1
    fi

    log_info "Keys generated successfully"
}

# 生成 AnyTLS 密码（32 个十六进制字符 = 128-bit，URI 安全，无需百分号编码）
gen_anytls_password() {
    ANYTLS_PASSWORD="${atpwd:-$(openssl rand -hex 16)}"
    log_info "AnyTLS 密码已生成"
}

# 生成随机化的 AnyTLS padding scheme（多行字符串，仅输出到 stdout）
#
# AnyTLS 通过 padding scheme 在协议层随机化数据包长度，以对抗基于
# 包长度分布的被动流量识别。官方默认方案是公开且固定的（容易被指纹库收录），
# 因此这里为每个节点生成独立、随机的方案。服务端方案会在握手时通过
# cmdUpdatePaddingScheme 自动下发给客户端（当客户端 padding-md5 不一致时），
# 所以无需客户端做任何额外配置即可生效。
#
# 格式: 第一行 stop=N 表示对前 N 个包（0..N-1）应用 padding；
#       随后每行 idx=seg[,seg...]，seg 为 "min-max"（区间随机长度）或 "c"（checkpoint）。
gen_anytls_padding() {
    local stop=$(( RANDOM % 5 + 4 ))   # stop ∈ [4,8]
    local -a lines
    lines+=("stop=${stop}")

    # 包 0 为认证包，使用较小的固定长度（模拟 TLS 握手记录）
    local p0=$(( RANDOM % 70 + 30 ))   # 30..99
    lines+=("0=${p0}-${p0}")

    local i s segs lo span hi line
    for (( i = 1; i < stop; i++ )); do
        segs=$(( RANDOM % 4 + 1 ))     # 每个包 1..4 个分段
        line="${i}="
        for (( s = 0; s < segs; s++ )); do
            lo=$(( RANDOM % 500 + 100 ))   # 100..599
            span=$(( RANDOM % 700 + 200 )) # 200..899
            hi=$(( lo + span ))
            (( hi > 1400 )) && hi=1400     # 控制在 ~MTU 以内，更贴近真实流量
            if (( s == 0 )); then
                line+="${lo}-${hi}"
            elif (( RANDOM % 2 == 0 )); then
                line+=",c,${lo}-${hi}"     # 以一定概率插入 checkpoint
            else
                line+=",${lo}-${hi}"
            fi
        done
        lines+=("$line")
    done

    printf '%s\n' "${lines[@]}"
}

# 为 plain AnyTLS 生成自签名证书（客户端使用 insecure=1 连接）
# Usage: gen_selfsigned_cert NAME CN
gen_selfsigned_cert() {
    local name="$1"
    local cn="${2:-www.bing.com}"
    mkdir -p "$SINGBOX_CERT_DIR"
    chmod 700 "$SINGBOX_CERT_DIR"
    local cert_path="$SINGBOX_CERT_DIR/${name}.crt"
    local key_path="$SINGBOX_CERT_DIR/${name}.key"

    openssl ecparam -genkey -name prime256v1 -out "$key_path" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$key_path" -out "$cert_path" \
        -subj "/CN=${cn}" 2>/dev/null
    chmod 600 "$key_path" "$cert_path"
}

# 统计 AnyTLS 节点数量
anytls_node_count() {
    local count=0 f t
    for f in "$NODES_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        t=$(safe_read_config_value "$f" "PROTOCOL_TYPE")
        [[ "$t" == "anytls" || "$t" == "anytls_reality" ]] && ((count++))
    done
    echo "$count"
}

# 验证 IPv4 地址格式
is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" -le 255 ]] || return 1
    done
    return 0
}

# 验证 IPv6 地址格式
is_valid_ipv6() {
    local ip="$1"
    # 简单验证：包含冒号且不包含非法字符
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:* ]]
}

# 全局 IP 变量
SERVER_IPV4=""
SERVER_IPV6=""

# 获取 IPv4 地址
get_ipv4() {
    local ip
    ip=$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi
    ip=$(curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv4 "$ip"; then
        echo "$ip"
        return 0
    fi
    echo ""
}

# 获取 IPv6 地址
get_ipv6() {
    local ip
    ip=$(curl -s6 --max-time 3 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv6 "$ip"; then
        echo "$ip"
        return 0
    fi
    ip=$(curl -s6 --max-time 3 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
    if is_valid_ipv6 "$ip"; then
        echo "$ip"
        return 0
    fi
    echo ""
}

# 检测网络栈类型
detect_network_stack() {
    log_info "$(msg detecting_ip)"

    SERVER_IPV4=$(get_ipv4)
    SERVER_IPV6=$(get_ipv6)

    if [[ -n "$SERVER_IPV4" ]] && [[ -n "$SERVER_IPV6" ]]; then
        log_info "Dual-Stack detected: IPv4=$SERVER_IPV4, IPv6=$SERVER_IPV6"
    elif [[ -n "$SERVER_IPV4" ]]; then
        log_info "IPv4 Only: $SERVER_IPV4"
    elif [[ -n "$SERVER_IPV6" ]]; then
        log_info "IPv6 Only: $SERVER_IPV6"
    else
        log_warn "Could not detect server IP automatically"
        SERVER_IPV4="YOUR_SERVER_IP"
    fi
}

# 并行获取服务器 IP 地址 (向后兼容)
get_server_ip_parallel() {
    local result_file pids=()
    result_file=$(mktemp)

    # IP 检测 API 列表
    local apis=(
        "https://api.ipify.org"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )

    # 并行请求所有 API
    for api in "${apis[@]}"; do
        (
            ip=$(curl -s --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
            if is_valid_ipv4 "$ip"; then
                echo "$ip" >> "$result_file"
            fi
        ) &
        pids+=($!)
    done

    # 等待第一个有效结果（最多 5 秒）
    local i=0
    while [[ $i -lt 50 ]]; do
        if [[ -s "$result_file" ]]; then
            local ip
            ip=$(head -n1 "$result_file")
            # 终止所有后台进程
            for pid in "${pids[@]}"; do
                kill "$pid" 2>/dev/null || true
            done
            wait 2>/dev/null || true
            rm -f "$result_file"
            echo "$ip"
            return 0
        fi
        sleep 0.1
        ((i++))
    done

    # 超时后清理
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true

    # 检查是否有结果
    if [[ -s "$result_file" ]]; then
        local ip
        ip=$(head -n1 "$result_file")
        rm -f "$result_file"
        echo "$ip"
        return 0
    fi

    rm -f "$result_file"
    echo "YOUR_SERVER_IP"
}

# 保存延迟缓存
save_latency_cache() {
    local -n cache_map=$1
    {
        echo "# timestamp: $(date +%s)"
        for domain in "${!cache_map[@]}"; do
            echo "$domain ${cache_map[$domain]}"
        done
    } > "$CACHE_FILE"
}

# 加载延迟缓存
# 返回 0 表示加载成功且缓存有效，返回 1 表示缓存无效或不存在
load_latency_cache() {
    local -n cache_map=$1

    # 检查缓存文件是否存在
    if [[ ! -f "$CACHE_FILE" ]]; then
        return 1
    fi

    # 读取时间戳并检查是否过期
    local timestamp
    timestamp=$(grep "^# timestamp:" "$CACHE_FILE" 2>/dev/null | awk '{print $3}')
    if [[ -z "$timestamp" ]]; then
        return 1
    fi

    local current_time
    current_time=$(date +%s)
    if (( current_time - timestamp > CACHE_TTL )); then
        return 1
    fi

    # 加载缓存数据
    while IFS=' ' read -r domain latency; do
        # 跳过注释行和空行
        [[ "$domain" =~ ^#.*$ || -z "$domain" ]] && continue
        cache_map["$domain"]=$latency
    done < "$CACHE_FILE"

    # 检查是否成功加载了数据
    if [[ ${#cache_map[@]} -eq 0 ]]; then
        return 1
    fi

    return 0
}

# 测试单个域名延迟
test_domain_latency() {
    local domain="$1"
    local t1 t2
    t1=$(date +%s%3N)
    if timeout 2 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null &>/dev/null; then
        t2=$(date +%s%3N)
        echo "$((t2 - t1))"
    else
        echo "9999"
    fi
}

# 测试单个域名并将结果写入文件（用于并行执行）
test_domain_to_file() {
    local domain="$1"
    local result_dir="$2"
    local latency
    latency=$(test_domain_latency "$domain")
    echo "$latency" > "${result_dir}/${domain}"
}

# 并行测试所有域名
# 参数1: 关联数组名称（用于存储结果）
# 设置全局变量 BEST_LATENCY 为最低延迟值
test_domains_parallel() {
    local -n _latency_map=$1
    local total=${#SNI_LIST[@]}
    local max_jobs=30
    local result_dir
    result_dir=$(mktemp -d)

    # 创建标记文件表示测试进行中
    local progress_flag="${result_dir}/.in_progress"
    touch "$progress_flag"

    # 清空结果数组
    _latency_map=()

    echo ""
    echo -e "${CYAN}$(msg testing)${NC}"

    # 启动进度显示后台进程
    (
        while [[ -f "$progress_flag" ]]; do
            local completed
            completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
            local percent=$((completed * 100 / total))
            printf "\r[%-50s] %d%% (%d/%d)          " \
                "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
                "$percent" "$completed" "$total"
            sleep 0.5
        done
    ) &
    local progress_pid=$!

    # 并行执行测试
    local running=0
    for domain in "${SNI_LIST[@]}"; do
        # 控制并发数
        while [[ $running -ge $max_jobs ]]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
        done

        # 启动后台任务
        test_domain_to_file "$domain" "$result_dir" &
        running=$((running + 1))
    done

    # 等待所有测试任务完成（不等待进度显示进程）
    # 通过检查结果文件数量来判断是否完成
    while true; do
        local completed
        completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
        if [[ "$completed" -ge "$total" ]]; then
            break
        fi
        sleep 0.2
    done

    # 停止进度显示（先删除 flag 让进程退出）
    rm -f "$progress_flag"
    sleep 0.3
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true

    # 显示最终进度
    printf "\r[%-50s] %d%% (%d/%d)          \n" \
        "$(printf '#%.0s' $(seq 1 50))" \
        "100" "$total" "$total"

    # 读取结果到关联数组
    local best_latency=9999
    for domain in "${SNI_LIST[@]}"; do
        local result_file="${result_dir}/${domain}"
        if [[ -f "$result_file" ]]; then
            local latency
            latency=$(cat "$result_file")
            # 验证 latency 是有效整数
            if [[ "$latency" =~ ^[0-9]+$ ]] && [[ "$latency" -ne 9999 ]]; then
                _latency_map["$domain"]=$latency
                if [[ "$latency" -lt "$best_latency" ]]; then
                    best_latency=$latency
                fi
            fi
        fi
    done

    # 清理临时目录
    rm -rf "$result_dir"

    echo ""

    # 返回最佳延迟值（通过全局变量）
    BEST_LATENCY=$best_latency
}

# 并行测试所有域名（带详细输出，用于 cmd_test_sni）
# 参数1: 关联数组名称（用于存储结果）
test_domains_parallel_verbose() {
    local -n _latency_map_v=$1
    local total=${#SNI_LIST[@]}
    local max_jobs=30
    local result_dir
    result_dir=$(mktemp -d)

    # 创建标记文件表示测试进行中
    local progress_flag="${result_dir}/.in_progress"
    touch "$progress_flag"

    # 清空结果数组
    _latency_map_v=()

    # 启动进度显示后台进程
    (
        while [[ -f "$progress_flag" ]]; do
            local completed
            completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
            local percent=$((completed * 100 / total))
            printf "\r${CYAN}$(msg testing)${NC} [%-50s] %d%% (%d/%d)          " \
                "$(printf '#%.0s' $(seq 1 $((percent / 2))))" \
                "$percent" "$completed" "$total"
            sleep 0.5
        done
    ) &
    local progress_pid=$!

    # 并行执行测试
    local running=0
    for domain in "${SNI_LIST[@]}"; do
        # 控制并发数
        while [[ $running -ge $max_jobs ]]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
        done

        # 启动后台任务
        test_domain_to_file "$domain" "$result_dir" &
        running=$((running + 1))
    done

    # 等待所有测试任务完成（不等待进度显示进程）
    while true; do
        local completed
        completed=$(find "$result_dir" -maxdepth 1 -type f ! -name '.in_progress' 2>/dev/null | wc -l)
        if [[ "$completed" -ge "$total" ]]; then
            break
        fi
        sleep 0.2
    done

    # 停止进度显示（先删除 flag 让进程退出）
    rm -f "$progress_flag"
    sleep 0.3
    kill $progress_pid 2>/dev/null || true
    wait $progress_pid 2>/dev/null || true

    # 清除进度行
    printf "\r%-80s\r" " "

    # 读取结果并显示详细信息
    local idx=0
    for domain in "${SNI_LIST[@]}"; do
        idx=$((idx + 1))
        local result_file="${result_dir}/${domain}"
        if [[ -f "$result_file" ]]; then
            local latency
            latency=$(cat "$result_file")
            # 验证 latency 是有效整数
            if [[ ! "$latency" =~ ^[0-9]+$ ]] || [[ "$latency" -eq 9999 ]]; then
                printf "[%3d/%3d] ${RED}%-50s $(msg timeout)${NC}\n" "$idx" "$total" "$domain"
            else
                printf "[%3d/%3d] ${GREEN}%-50s %dms${NC}\n" "$idx" "$total" "$domain" "$latency"
                _latency_map_v["$domain"]=$latency
            fi
        fi
    done

    # 清理临时目录
    rm -rf "$result_dir"
}

# 动态选择最低延迟的 SNI（测试所有域名）
select_best_sni() {
    local total=${#SNI_LIST[@]}
    declare -A latency_map
    local best_latency=9999
    local cache_loaded=0

    # 尝试加载缓存
    if load_latency_cache latency_map; then
        cache_loaded=1
        log_info "Using cached SNI latency results (valid for $((CACHE_TTL / 60)) minutes)"
        # 从缓存计算最低延迟
        for domain in "${!latency_map[@]}"; do
            if [[ "${latency_map[$domain]}" -lt "$best_latency" ]]; then
                best_latency="${latency_map[$domain]}"
            fi
        done
    else
        # 缓存无效，执行并行测试
        log_info "$(msg testing_sni) ($(msg total_domains): $total)"

        # 使用并行测试
        test_domains_parallel latency_map
        best_latency=$BEST_LATENCY

        # 保存测试结果到缓存
        if [[ ${#latency_map[@]} -gt 0 ]]; then
            save_latency_cache latency_map
        fi
    fi

    # 检查是否有可用域名
    if [[ ${#latency_map[@]} -eq 0 ]]; then
        log_warn "$(msg sni_timeout)"
        # 即使测试失败也让用户选择
        prompt_sni_choice "" ""
        return
    fi

    # 获取排序后的 Top 5 域名
    local top_domains=()
    local top_latencies=()
    while IFS=' ' read -r lat dom; do
        top_domains+=("$dom")
        top_latencies+=("$lat")
    done < <(for domain in "${!latency_map[@]}"; do
        echo "${latency_map[$domain]} $domain"
    done | sort -n | head -5)

    # 让用户选择 SNI
    prompt_sni_choice top_domains top_latencies
}

# 让用户选择 SNI 的交互函数
# 参数1: top_domains 数组名称
# 参数2: top_latencies 数组名称
# 测试用户手动输入的逗号分隔域名列表，把排序后的结果写入传入的两个数组
# 用法: _run_custom_sni_test OUT_DOMAINS_ARR OUT_LATENCIES_ARR
_run_custom_sni_test() {
    local -n _out_domains=$1
    local -n _out_lats=$2

    {
    echo ""
    echo -e "  ${CYAN}$(msg sni_custom_test_hint)${NC}"
    echo -n "  > "
    } >/dev/tty

    local raw
    read -r raw </dev/tty

    # 按逗号分隔解析，逐个清洗并校验域名格式
    local -a parts=() domains=()
    IFS=',' read -ra parts <<< "$raw"
    local part
    for part in "${parts[@]}"; do
        part=$(echo "$part" | sed 's#^https\?://##; s#/.*$##' | tr -d '[:space:]')
        [[ -n "$part" ]] || continue
        if [[ "$part" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
            domains+=("$part")
        else
            log_warn "$(msg sni_invalid_format): $part"
        fi
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        log_warn "$(msg sni_empty_input)"
        return 1
    fi

    # 仅测试这些自定义域名：临时替换 SNI_LIST，不读取也不写入内置缓存
    declare -A _lat
    local _saved_list=("${SNI_LIST[@]}")
    SNI_LIST=("${domains[@]}")
    test_domains_parallel _lat
    SNI_LIST=("${_saved_list[@]}")

    if [[ ${#_lat[@]} -eq 0 ]]; then
        log_warn "$(msg sni_custom_unreachable)"
        return 1
    fi

    # 排序取延迟最低的前 5 个，写回输出数组供选择
    _out_domains=()
    _out_lats=()
    local lat dom
    while IFS=' ' read -r lat dom; do
        _out_domains+=("$dom")
        _out_lats+=("$lat")
    done < <(for dom in "${!_lat[@]}"; do echo "${_lat[$dom]} $dom"; done | sort -n | head -5)

    log_info "$(msg sni_custom_test_done)"
    return 0
}

prompt_sni_choice() {
    local -n _in_domains=$1 2>/dev/null || true
    local -n _in_latencies=$2 2>/dev/null || true
    # 拷贝到本地可变数组；选择"测试自定义域名"后会用自定义结果替换它们
    local -a td=() tl=()
    if [[ ${#_in_domains[@]} -gt 0 ]] 2>/dev/null; then
        td=("${_in_domains[@]}")
        tl=("${_in_latencies[@]}")
    fi

    while true; do
        local has_results=false
        [[ ${#td[@]} -gt 0 ]] && has_results=true

        {
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                     $(msg sni_selection_title)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""

        if $has_results; then
            echo -e "  ${BLUE}$(msg sni_top_results):${NC}"
            echo ""
            local i=1 idx
            for idx in "${!td[@]}"; do
                printf "    ${GREEN}%d.${NC} %-40s ${YELLOW}%dms${NC}\n" "$i" "${td[$idx]}" "${tl[$idx]}"
                ((i++))
            done
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  ${GREEN}A.${NC} $(msg sni_auto_select) (${td[0]})"
            echo -e "  ${GREEN}M.${NC} $(msg sni_manual_input)"
            echo -e "  ${GREEN}C.${NC} $(msg sni_custom_test)"
            echo ""
            echo -n "  $(msg sni_choice_prompt) [A/1-5/M/C]: "
        else
            echo -e "  ${YELLOW}$(msg sni_no_results)${NC}"
            echo ""
            echo -e "  ${GREEN}D.${NC} $(msg sni_use_default) (www.tesla.com)"
            echo -e "  ${GREEN}M.${NC} $(msg sni_manual_input)"
            echo -e "  ${GREEN}C.${NC} $(msg sni_custom_test)"
            echo ""
            echo -n "  $(msg sni_choice_prompt) [D/M/C]: "
        fi
        } >/dev/tty

        local choice
        read -r choice </dev/tty
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

        if $has_results; then
            case "$choice" in
                A|"")
                    SNI="${td[0]}"
                    log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[0]}ms)"
                    return ;;
                [1-9]|[1-9][0-9])
                    local idx=$((choice - 1))
                    if [[ $idx -ge 0 && $idx -lt ${#td[@]} ]]; then
                        SNI="${td[$idx]}"
                        log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[$idx]}ms)"
                    else
                        SNI="${td[0]}"
                        log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[0]}ms)"
                    fi
                    return ;;
                M)
                    prompt_custom_sni
                    return ;;
                C)
                    # 测试自定义域名列表，并用结果替换候选集后重新展示
                    _run_custom_sni_test td tl || true
                    continue ;;
                *)
                    SNI="${td[0]}"
                    log_info "$(msg sni_selected): ${SNI} ($(msg latency): ${tl[0]}ms)"
                    return ;;
            esac
        else
            case "$choice" in
                D|"")
                    SNI="www.tesla.com"
                    log_info "$(msg sni_use_default): ${SNI}"
                    return ;;
                M)
                    prompt_custom_sni
                    return ;;
                C)
                    _run_custom_sni_test td tl || true
                    continue ;;
                *)
                    SNI="www.tesla.com"
                    log_info "$(msg sni_use_default): ${SNI}"
                    return ;;
            esac
        fi
    done
}

# 提示用户输入自定义 SNI
prompt_custom_sni() {
    {
    echo ""
    echo -e "  ${CYAN}$(msg sni_input_hint)${NC}"
    echo -n "  SNI: "
    } >/dev/tty

    read -r custom_sni </dev/tty

    # 清理输入（移除空格和协议前缀）
    custom_sni=$(echo "$custom_sni" | sed 's/^https\?:\/\///' | sed 's/\/.*$//' | tr -d '[:space:]')

    if [[ -z "$custom_sni" ]]; then
        SNI="www.tesla.com"
        log_warn "$(msg sni_empty_input), $(msg sni_use_default): ${SNI}"
    else
        # 验证域名格式
        if [[ "$custom_sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
            SNI="$custom_sni"
            log_info "$(msg sni_custom_set): ${SNI}"

            # 可选：测试自定义域名连通性
            echo -e "  ${CYAN}$(msg sni_testing_custom)...${NC}" >/dev/tty
            if timeout 3 openssl s_client -connect "${SNI}:443" -servername "$SNI" </dev/null &>/dev/null; then
                log_info "$(msg sni_custom_ok)"
            else
                log_warn "$(msg sni_custom_unreachable)"
            fi
        else
            log_warn "$(msg sni_invalid_format), $(msg sni_use_default)"
            SNI="www.tesla.com"
        fi
    fi
}

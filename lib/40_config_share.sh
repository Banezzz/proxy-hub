# 验证 Xray 配置文件有效性
validate_xray_config() {
    if [[ ! -f "$XRAY_CONF" ]]; then
        log_error "Config file not found: $XRAY_CONF"
        return 1
    fi

    # 检查文件不为空
    if [[ ! -s "$XRAY_CONF" ]]; then
        log_error "Config file is empty"
        return 1
    fi

    # 检查 JSON 有效性
    if ! jq . "$XRAY_CONF" > /dev/null 2>&1; then
        log_error "Config file contains invalid JSON"
        return 1
    fi

    # 如果 xray 可用，使用 xray -test 验证
    if command -v "$XRAY_BIN" &>/dev/null; then
        local test_output
        if ! test_output=$("$XRAY_BIN" -test -config "$XRAY_CONF" 2>&1); then
            log_error "Xray config test failed: $test_output"
            return 1
        fi
    fi

    return 0
}

# 验证 sing-box 配置文件有效性
validate_singbox_config() {
    if [[ ! -f "$SINGBOX_CONF" ]]; then
        log_error "sing-box config not found: $SINGBOX_CONF"
        return 1
    fi
    if [[ ! -s "$SINGBOX_CONF" ]]; then
        log_error "sing-box config is empty"
        return 1
    fi
    if ! jq . "$SINGBOX_CONF" > /dev/null 2>&1; then
        log_error "sing-box config contains invalid JSON"
        return 1
    fi
    if [[ -x "$SINGBOX_BIN" ]]; then
        local test_output
        if ! test_output=$("$SINGBOX_BIN" check -c "$SINGBOX_CONF" 2>&1); then
            log_error "sing-box config check failed: $test_output"
            return 1
        fi
    fi
    return 0
}

write_config() {
    mkdir -p /usr/local/etc/xray

    # 构建 inbounds 数组
    local inbounds_json="[]"

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue

        # 使用安全的配置读取方式（防止命令注入）
        local n_name n_port n_uuid n_sni n_private_key n_short_id n_xhttp_port n_xhttp_path n_protocol_type
        local n_ss_method n_ss_password
        n_name=$(safe_read_config_value "$node_file" "NODE_NAME")
        n_port=$(safe_read_config_value "$node_file" "PORT")
        n_uuid=$(safe_read_config_value "$node_file" "UUID")
        n_sni=$(safe_read_config_value "$node_file" "SNI")
        n_private_key=$(safe_read_config_value "$node_file" "PRIVATE_KEY")
        n_short_id=$(safe_read_config_value "$node_file" "SHORT_ID")
        n_xhttp_port=$(safe_read_config_value "$node_file" "XHTTP_PORT")
        n_xhttp_path=$(safe_read_config_value "$node_file" "XHTTP_PATH")
        n_protocol_type=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")
        n_ss_method=$(safe_read_config_value "$node_file" "SS_METHOD")
        n_ss_password=$(safe_read_config_value "$node_file" "SS_PASSWORD")

        # 处理可能加密的敏感值
        n_private_key=$(decrypt_value "$n_private_key")
        n_uuid=$(decrypt_value "$n_uuid")
        n_ss_password=$(decrypt_value "$n_ss_password")

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

        # AnyTLS / Hysteria2 节点由 sing-box 处理，Xray 配置中跳过
        if [[ "$n_protocol_type" == "anytls" || "$n_protocol_type" == "anytls_reality" || "$n_protocol_type" == "hysteria2" ]]; then
            continue
        fi

        # 跳过无效节点（VLESS 需要 UUID，Shadowsocks 需要密码）
        if [[ "$n_protocol_type" == "shadowsocks" ]]; then
            [[ -z "$n_ss_password" ]] && continue
        else
            [[ -z "$n_uuid" ]] && continue
        fi

        # 添加 Shadowsocks inbound
        if [[ "$n_protocol_type" == "shadowsocks" ]] && [[ -n "$n_port" ]] && [[ -n "$n_ss_method" ]] && [[ -n "$n_ss_password" ]]; then
            local validated_port
            validated_port=$(get_validated_port "$n_port" true)
            if [[ -z "$validated_port" ]]; then
                log_warn "Invalid Shadowsocks port for node '$n_name', skipping"
                continue
            fi

            local ss_inbound
            ss_inbound=$(build_shadowsocks_inbound "$n_name" "$validated_port" "$n_ss_method" "$n_ss_password")
            if [[ -z "$ss_inbound" ]]; then
                log_error "Failed to build Shadowsocks inbound for node '$n_name'"
                return 1
            fi

            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$ss_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add Shadowsocks inbound for node '$n_name': $new_inbounds"
                return 1
            fi
            continue  # Shadowsocks 节点处理完毕，跳过 VLESS 处理
        fi

        # 添加 Vision inbound（如果协议类型包含 vision）
        if [[ "$n_protocol_type" == "vision" || "$n_protocol_type" == "both" ]] && [[ -n "$n_port" ]]; then
            # 验证端口（安全检查）
            local validated_port
            validated_port=$(get_validated_port "$n_port" true)
            if [[ -z "$validated_port" ]]; then
                log_warn "Invalid Vision port for node '$n_name', skipping"
                continue
            fi

            # 使用安全的 JSON 构建器（防止注入）
            local vision_inbound
            vision_inbound=$(build_vision_inbound "$n_name" "$validated_port" "$n_uuid" "$n_sni" "$n_private_key" "$n_short_id")
            if [[ -z "$vision_inbound" ]]; then
                log_error "Failed to build Vision inbound for node '$n_name'"
                return 1
            fi

            # 使用临时变量和错误检查来防止 jq 失败导致脚本退出
            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$vision_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add Vision inbound for node '$n_name': $new_inbounds"
                return 1
            fi
        fi

        # 添加 XHTTP inbound（如果协议类型包含 xhttp）
        if [[ "$n_protocol_type" == "xhttp" || "$n_protocol_type" == "both" ]] && [[ -n "$n_xhttp_port" ]] && [[ -n "$n_xhttp_path" ]]; then
            # 验证端口（安全检查）
            local validated_xhttp_port
            validated_xhttp_port=$(get_validated_port "$n_xhttp_port" true)
            if [[ -z "$validated_xhttp_port" ]]; then
                log_warn "Invalid XHTTP port for node '$n_name', skipping"
                continue
            fi

            # 使用安全的 JSON 构建器（防止注入）
            local xhttp_inbound
            xhttp_inbound=$(build_xhttp_inbound "$n_name" "$validated_xhttp_port" "$n_uuid" "$n_sni" "$n_private_key" "$n_short_id" "$n_xhttp_path")
            if [[ -z "$xhttp_inbound" ]]; then
                log_error "Failed to build XHTTP inbound for node '$n_name'"
                return 1
            fi

            # 使用临时变量和错误检查来防止 jq 失败导致脚本退出
            local new_inbounds
            if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$xhttp_inbound" '. += [$inbound]' 2>&1); then
                inbounds_json="$new_inbounds"
            else
                log_error "Failed to add XHTTP inbound for node '$n_name': $new_inbounds"
                return 1
            fi
        fi
    done

    # 构建 outbounds
    local outbounds_json='[{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]'

    # 检查是否有 WARP 代理
    if check_warp_running; then
        local warp_outbound='{"tag": "warp_proxy", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": '$WARP_SOCKS_PORT'}]}}'
        local new_outbounds
        if new_outbounds=$(echo "$outbounds_json" | jq --argjson outbound "$warp_outbound" '. += [$outbound]' 2>&1); then
            outbounds_json="$new_outbounds"
        else
            log_error "Failed to add WARP outbound: $new_outbounds"
            return 1
        fi
    fi

    # 构建路由规则
    local routing_json
    routing_json=$(cat <<EOF
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    {"type": "field", "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10", "::1/128", "fc00::/7", "fe80::/10"], "outboundTag": "block"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
  ]
}
EOF
)

    # 检查并添加 WARP 分流规则
    if [[ -f "/root/.warp_netflix" ]] && check_warp_running; then
        local new_routing
        if new_routing=$(echo "$routing_json" | jq '.rules = [{"type": "field", "domain": ["geosite:netflix"], "outboundTag": "warp_proxy"}] + .rules' 2>&1); then
            routing_json="$new_routing"
        else
            log_warn "Failed to add Netflix routing rule: $new_routing"
        fi
    fi
    if [[ -f "/root/.warp_ai" ]] && check_warp_running; then
        local new_routing
        if new_routing=$(echo "$routing_json" | jq '.rules = [{"type": "field", "domain": ["geosite:openai", "geosite:anthropic"], "outboundTag": "warp_proxy"}] + .rules' 2>&1); then
            routing_json="$new_routing"
        else
            log_warn "Failed to add AI routing rule: $new_routing"
        fi
    fi

    # 组装最终配置
    local config_json
    if ! config_json=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        --argjson outbounds "$outbounds_json" \
        --argjson routing "$routing_json" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": $inbounds,
            "outbounds": $outbounds,
            "routing": $routing
        }' 2>&1); then
        log_error "Failed to assemble final config: $config_json"
        return 1
    fi

    echo "$config_json" > "$XRAY_CONF"

    # 验证配置文件有效性
    if ! validate_xray_config; then
        log_error "Generated config is invalid"
        return 1
    fi

    return 0
}

# 根据所有 AnyTLS / Hysteria2 节点生成 sing-box 配置文件
write_singbox_config() {
    mkdir -p "$SINGBOX_DIR"

    local inbounds_json="[]"

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue

        local n_proto
        n_proto=$(safe_read_config_value "$node_file" "PROTOCOL_TYPE")
        [[ "$n_proto" == "anytls" || "$n_proto" == "anytls_reality" || "$n_proto" == "hysteria2" ]] || continue

        local n_name n_port n_sni n_priv n_sid n_pw n_pad_b64 n_pad
        n_name=$(safe_read_config_value "$node_file" "NODE_NAME")
        n_port=$(safe_read_config_value "$node_file" "PORT")
        n_sni=$(safe_read_config_value "$node_file" "SNI")
        n_priv=$(safe_read_config_value "$node_file" "PRIVATE_KEY")
        n_sid=$(safe_read_config_value "$node_file" "SHORT_ID")
        if [[ "$n_proto" == "hysteria2" ]]; then
            n_pw=$(safe_read_config_value "$node_file" "HY2_PASSWORD")
        else
            n_pw=$(safe_read_config_value "$node_file" "ANYTLS_PASSWORD")
        fi
        n_pad_b64=$(safe_read_config_value "$node_file" "ANYTLS_PADDING_B64")

        # 解密可能加密的敏感值
        n_priv=$(decrypt_value "$n_priv")
        n_pw=$(decrypt_value "$n_pw")

        [[ -z "$n_pw" ]] && continue

        local validated_port
        validated_port=$(get_validated_port "$n_port" true)
        if [[ -z "$validated_port" ]]; then
            log_warn "Invalid sing-box port for node '$n_name', skipping"
            continue
        fi

        local inbound
        if [[ "$n_proto" == "hysteria2" ]]; then
            local cert_path="$SINGBOX_CERT_DIR/${n_name}.crt"
            local key_path="$SINGBOX_CERT_DIR/${n_name}.key"
            if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                gen_selfsigned_cert "$n_name" "${n_sni:-www.bing.com}" || return 1
            fi
            if ! inbound=$(build_hysteria2_inbound "$n_name" "$validated_port" "$n_pw" \
                "${n_sni:-www.bing.com}" "$cert_path" "$key_path"); then
                log_error "Failed to build Hysteria2 inbound for node '$n_name'"
                return 1
            fi
        else
            # 还原 AnyTLS padding scheme；缺失时即时生成随机方案。
            n_pad=""
            if [[ -n "$n_pad_b64" ]]; then
                n_pad=$(echo "$n_pad_b64" | base64 -d 2>/dev/null)
            fi
            [[ -z "$n_pad" ]] && n_pad=$(gen_anytls_padding)
        fi

        if [[ "$n_proto" == "anytls_reality" ]]; then
            inbound=$(build_anytls_inbound "$n_name" "$validated_port" "$n_pw" "$n_pad" \
                "reality" "$n_sni" "$n_priv" "$n_sid" "" "")
        elif [[ "$n_proto" == "anytls" ]]; then
            local cert_path="$SINGBOX_CERT_DIR/${n_name}.crt"
            local key_path="$SINGBOX_CERT_DIR/${n_name}.key"
            # 确保自签名证书存在
            if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
                gen_selfsigned_cert "$n_name" "${n_sni:-www.bing.com}"
            fi
            inbound=$(build_anytls_inbound "$n_name" "$validated_port" "$n_pw" "$n_pad" \
                "tls" "${n_sni:-www.bing.com}" "" "" "$cert_path" "$key_path")
        fi

        if [[ -z "$inbound" ]]; then
            log_error "Failed to build $n_proto inbound for node '$n_name'"
            return 1
        fi

        local new_inbounds
        if new_inbounds=$(echo "$inbounds_json" | jq --argjson inbound "$inbound" '. += [$inbound]' 2>&1); then
            inbounds_json="$new_inbounds"
        else
            log_error "Failed to add $n_proto inbound for node '$n_name': $new_inbounds"
            return 1
        fi
    done

    local config_json
    if ! config_json=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        '{
            "log": {"level": "warn", "timestamp": true},
            "inbounds": $inbounds,
            "outbounds": [{"type": "direct", "tag": "direct"}],
            "route": {"final": "direct"}
        }' 2>&1); then
        log_error "Failed to assemble sing-box config: $config_json"
        return 1
    fi

    echo "$config_json" > "$SINGBOX_CONF"
    chmod 600 "$SINGBOX_CONF"

    if ! validate_singbox_config; then
        log_error "Generated sing-box config is invalid"
        return 1
    fi

    return 0
}

# 同步 sing-box 状态：有 AnyTLS / Hysteria2 节点则（安装并）写配置、启动服务；
# 没有则停止并禁用服务。在添加/删除节点后调用。
singbox_sync() {
    local count
    count=$(singbox_node_count)

    if [[ "$count" -eq 0 ]]; then
        # 没有 AnyTLS 节点，停止 sing-box（如果存在）
        if [[ -f "$SINGBOX_BIN" ]]; then
            service_stop "$SINGBOX_SERVICE"
            service_disable "$SINGBOX_SERVICE"
        fi
        rm -f "$SINGBOX_CONF" 2>/dev/null
        return 0
    fi

    # 有 AnyTLS 节点，确保 sing-box 已安装
    if [[ ! -f "$SINGBOX_BIN" ]]; then
        if ! install_singbox; then
            log_error "Failed to install sing-box"
            return 1
        fi
    fi

    if ! write_singbox_config; then
        return 1
    fi

    service_enable "$SINGBOX_SERVICE"
    if ! service_restart "$SINGBOX_SERVICE"; then
        log_error "sing-box service restart failed"
        return 1
    fi

    sleep 1
    if ! service_is_active "$SINGBOX_SERVICE"; then
        log_error "sing-box service failed to become active"
        return 1
    fi
    return 0
}

# 检查 WARP 是否运行
check_warp_running() {
    (echo > /dev/tcp/127.0.0.1/$WARP_SOCKS_PORT) 2>/dev/null
}

save_env() {
    init_nodes_dir

    # 使用节点名称或端口作为文件名
    local node_name="${CURRENT_NODE_NAME:-$PORT}"
    local node_file
    node_file=$(get_node_file "$node_name")

    # 使用检测到的 IP（优先使用 SERVER_IPV4，向后兼容 SERVER_IP）
    local save_ipv4="${SERVER_IPV4:-$SERVER_IP}"
    local save_ipv6="${SERVER_IPV6:-}"

    # Optional: encrypt sensitive values if encryption is enabled
    local save_uuid="$UUID"
    local save_private_key="$PRIVATE_KEY"
    local save_ss_password="${SS_PASSWORD:-}"
    local save_anytls_password="${ANYTLS_PASSWORD:-}"
    local save_hy2_password="${HY2_PASSWORD:-}"

    if is_encryption_enabled; then
        save_uuid=$(encrypt_value "$UUID")
        save_private_key=$(encrypt_value "$PRIVATE_KEY")
        [[ -n "$save_ss_password" ]] && save_ss_password=$(encrypt_value "$SS_PASSWORD")
        [[ -n "$save_anytls_password" ]] && save_anytls_password=$(encrypt_value "$ANYTLS_PASSWORD")
        [[ -n "$save_hy2_password" ]] && save_hy2_password=$(encrypt_value "$HY2_PASSWORD")
    fi

    cat > "$node_file" <<ENV
NODE_NAME=$node_name
SERVER_IP=${save_ipv4:-YOUR_SERVER_IP}
SERVER_IPV4=${save_ipv4:-}
SERVER_IPV6=${save_ipv6:-}
PORT=${PORT:-}
UUID=$save_uuid
SNI=$SNI
PUBLIC_KEY=$PUBLIC_KEY
PRIVATE_KEY=$save_private_key
SHORT_ID=$SHORT_ID
PROTOCOL_TYPE=${PROTOCOL_TYPE:-vision}
XHTTP_PORT=${XHTTP_PORT:-}
XHTTP_PATH=${XHTTP_PATH:-}
SS_METHOD=${SS_METHOD:-}
SS_PASSWORD=$save_ss_password
ANYTLS_PASSWORD=$save_anytls_password
ANYTLS_PADDING_B64=${ANYTLS_PADDING_B64:-}
HY2_PASSWORD=$save_hy2_password
ENV
    chmod 600 "$node_file"

    CURRENT_NODE_NAME="$node_name"
}

# 生成 Vision 分享链接
get_vision_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    echo "vless://${UUID}@${ip_formatted}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${node_label}"
}

# 生成 XHTTP 分享链接
get_xhttp_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # 注意：XHTTP 不需要 flow 参数，path 需要 URL 编码
    local encoded_path
    encoded_path=$(echo -n "$XHTTP_PATH" | sed 's|/|%2F|g')
    echo "vless://${UUID}@${ip_formatted}:${XHTTP_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=xhttp&path=${encoded_path}&sni=${SNI}&sid=${SHORT_ID}#${node_label}"
}

# 生成 Shadowsocks 分享链接
# 格式: ss://BASE64(method:password)@host:port#name
get_ss_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # SS 链接格式: ss://BASE64(method:password)@server:port#tag
    local userinfo
    userinfo=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)
    echo "ss://${userinfo}@${ip_formatted}:${PORT}#${node_label}"
}

# 生成 AnyTLS 分享链接
# 格式: anytls://PASSWORD@host:port/?sni=...[&insecure=1 | &pbk=...&sid=...&fp=chrome]#name
get_anytls_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    # IPv6 需要方括号
    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    # 密码为十六进制字符串，URI 安全，无需百分号编码
    local pw="${ANYTLS_PASSWORD}"
    local sni="${SNI:-www.bing.com}"

    if [[ "${PROTOCOL_TYPE}" == "anytls_reality" ]]; then
        # REALITY 伪装：携带公钥/short-id/指纹
        echo "anytls://${pw}@${ip_formatted}:${PORT}/?sni=${sni}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&fp=chrome#${node_label}"
    else
        # 自签名证书：客户端需允许不安全连接
        echo "anytls://${pw}@${ip_formatted}:${PORT}/?sni=${sni}&insecure=1#${node_label}"
    fi
}

# 生成 Hysteria2 分享链接。密码被限制在 URI-unreserved 字符集内。
get_hy2_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"

    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    echo "hysteria2://${HY2_PASSWORD}@${ip_formatted}:${PORT}/?sni=${SNI:-www.bing.com}&insecure=1#${node_label}"
}

# 向后兼容的获取分享链接函数
get_share_link() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    # 使用安全的配置加载（防止命令注入）
    safe_load_node_config "$node_file"
    local node_label="${NODE_NAME:-RV-Reality}"
    local ip="${SERVER_IPV4:-${SERVER_IPV6:-$SERVER_IP}}"
    local proto_type="${PROTOCOL_TYPE:-vision}"

    # 根据协议类型返回对应的链接
    if [[ "$proto_type" == "hysteria2" ]] && [[ -n "${HY2_PASSWORD:-}" ]]; then
        HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")
        get_hy2_link "$ip" "${node_label}_Hysteria2"
    elif [[ "$proto_type" == "shadowsocks" ]] && [[ -n "${SS_PASSWORD:-}" ]]; then
        # Shadowsocks 节点
        get_ss_link "$ip" "${node_label}_SS"
    elif [[ "$proto_type" == "anytls" || "$proto_type" == "anytls_reality" ]] && [[ -n "${ANYTLS_PASSWORD:-}" ]]; then
        # AnyTLS 节点
        ANYTLS_PASSWORD=$(decrypt_value "$ANYTLS_PASSWORD")
        get_anytls_link "$ip" "${node_label}_AnyTLS"
    elif [[ "$proto_type" == "xhttp" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
        # XHTTP-only 节点
        get_xhttp_link "$ip" "${node_label}_XHTTP"
    elif [[ -n "${PORT:-}" ]]; then
        # Vision 节点或 both 节点（优先显示 Vision）
        get_vision_link "$ip" "$node_label"
    elif [[ -n "${XHTTP_PORT:-}" ]]; then
        # 后备：如果没有 Vision 端口，使用 XHTTP
        get_xhttp_link "$ip" "${node_label}_XHTTP"
    else
        echo ""
    fi
}

# 显示当前节点的全部二维码。get_share_link 保持单链接兼容契约；only
# the presentation path expands a `both` node into Vision + XHTTP.
show_node_qrcodes() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    safe_load_node_config "$node_file" || return 1

    local node_label="${NODE_NAME:-RV-Reality}"
    local ip="${SERVER_IPV4:-${SERVER_IPV6:-$SERVER_IP}}"
    local proto_type="${PROTOCOL_TYPE:-vision}"
    local shown=0 link

    if [[ "$proto_type" == "both" ]]; then
        if [[ -n "${PORT:-}" ]]; then
            show_qrcode "$(get_vision_link "$ip" "${node_label}_Vision")"
            ((++shown))
        fi
        if [[ -n "${XHTTP_PORT:-}" ]]; then
            show_qrcode "$(get_xhttp_link "$ip" "${node_label}_XHTTP")"
            ((++shown))
        fi
    else
        link=$(get_share_link)
        if [[ -n "$link" ]]; then
            show_qrcode "$link"
            shown=1
        fi
    fi

    if [[ "$shown" -eq 0 ]]; then
        log_error "没有可用的节点链接 / No usable node link"
        return 1
    fi
}

show_qrcode() {
    local link="$1"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    $(msg qr_title)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$link"
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}$(msg share_link):${NC}"
    echo -e "${YELLOW}$link${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${MAGENTA}$(msg qr_tip)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# 在 63 宽的标题框内居中输出（近似处理 CJK 双宽字符：显示宽度≈(字符数+字节数)/2）
_center_title() {
    local text="$1"
    local total=63 chars bytes width pad pad_str
    chars=$(printf '%s' "$text" | wc -m 2>/dev/null || echo 0)
    bytes=$(printf '%s' "$text" | wc -c 2>/dev/null || echo 0)
    [[ "${chars:-0}" -le 0 ]] && chars=${#text}
    width=$(( (chars + bytes) / 2 ))
    pad=$(( (total - width) / 2 ))
    (( pad < 0 )) && pad=0
    pad_str=$(printf '%*s' "$pad" '')
    echo -e "${GREEN}${pad_str}${text}${NC}"
}

show_info() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    # 使用安全的配置加载（防止命令注入）
    safe_load_node_config "$node_file"

    local hostname
    hostname=$(hostname 2>/dev/null || echo "server")

    # 协议类型与人类可读名称（用于标题与协议字段）
    local proto_type="${PROTOCOL_TYPE:-both}"
    local proto_label
    case "$proto_type" in
        vision)          proto_label="VLESS Vision + REALITY" ;;
        xhttp)           proto_label="VLESS XHTTP + REALITY" ;;
        both)            proto_label="VLESS Vision + XHTTP + REALITY" ;;
        shadowsocks)     proto_label="Shadowsocks 2022" ;;
        anytls)          proto_label="AnyTLS" ;;
        anytls_reality)  proto_label="AnyTLS + REALITY" ;;
        hysteria2)       proto_label="Hysteria2" ;;
        *)               proto_label="$proto_type" ;;
    esac

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    _center_title "${proto_label}  $(msg node_info_suffix)"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BLUE}Node Name:${NC}   ${NODE_NAME:-$CURRENT_NODE_NAME}"
    echo -e "  ${BLUE}协议类型:${NC}    $proto_label"
    if [[ -n "${SERVER_IPV4:-}" ]]; then
        echo -e "  ${BLUE}IPv4:${NC}        $SERVER_IPV4"
    fi
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        echo -e "  ${BLUE}IPv6:${NC}        $SERVER_IPV6"
    fi
    if [[ -z "${SERVER_IPV4:-}" ]] && [[ -z "${SERVER_IPV6:-}" ]]; then
        echo -e "  ${BLUE}$(msg server_addr):${NC} ${SERVER_IP:-N/A}"
    fi

    # Shadowsocks 节点显示不同信息
    if [[ "$proto_type" == "shadowsocks" ]]; then
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A}"
        echo -e "  ${BLUE}Method:${NC}      ${SS_METHOD:-N/A}"
        echo -e "  ${BLUE}Password:${NC}    ${SS_PASSWORD:-N/A}"
        echo -e "  ${BLUE}Network:${NC}     tcp,udp"
        echo ""

        # Shadowsocks IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV4" "${hostname}_SS_v4")"
        fi

        # Shadowsocks IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV6" "${hostname}_SS_v6")"
        fi
    elif [[ "$proto_type" == "hysteria2" ]]; then
        HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A} (UDP/QUIC)"
        echo -e "  ${BLUE}Password:${NC}    ${HY2_PASSWORD:-N/A}"
        echo -e "  ${BLUE}Transport:${NC}   Hysteria2 (sing-box)"
        echo -e "  ${BLUE}SNI:${NC}         ${SNI:-www.bing.com}"
        echo -e "  ${BLUE}Insecure:${NC}    true  ${GRAY}(self-signed certificate)${NC}"
        echo ""

        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Hysteria2:${NC}"
            echo -e "  $(get_hy2_link "$SERVER_IPV4" "${hostname}_Hysteria2_v4")"
        fi
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Hysteria2:${NC}"
            echo -e "  $(get_hy2_link "$SERVER_IPV6" "${hostname}_Hysteria2_v6")"
        fi
    elif [[ "$proto_type" == "anytls" || "$proto_type" == "anytls_reality" ]]; then
        # AnyTLS 节点显示
        ANYTLS_PASSWORD=$(decrypt_value "$ANYTLS_PASSWORD")
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A}"
        echo -e "  ${BLUE}Password:${NC}    ${ANYTLS_PASSWORD:-N/A}"
        echo -e "  ${BLUE}Transport:${NC}   AnyTLS (sing-box)"
        if [[ "$proto_type" == "anytls_reality" ]]; then
            echo -e "  ${BLUE}Security:${NC}    reality"
            echo -e "  ${BLUE}SNI:${NC}         $SNI"
            echo -e "  ${BLUE}PublicKey:${NC}   $PUBLIC_KEY"
            echo -e "  ${BLUE}ShortID:${NC}     $SHORT_ID"
            echo -e "  ${BLUE}Fingerprint:${NC} chrome"
        else
            echo -e "  ${BLUE}Security:${NC}    tls (self-signed)"
            echo -e "  ${BLUE}SNI:${NC}         ${SNI:-N/A}  ${GRAY}(证书 CN / cert CN)${NC}"
            echo -e "  ${BLUE}Insecure:${NC}    true  ${GRAY}(客户端需允许不安全连接)${NC}"
        fi

        # Padding scheme（base64 解码后展示）：每个节点随机生成，握手时自动下发给客户端
        local at_pad_b64 at_pad_text
        at_pad_b64=$(safe_read_config_value "$node_file" "ANYTLS_PADDING_B64")
        if [[ -n "$at_pad_b64" ]]; then
            at_pad_text=$(echo "$at_pad_b64" | base64 -d 2>/dev/null)
        fi
        if [[ -n "${at_pad_text:-}" ]]; then
            echo -e "  ${BLUE}Padding:${NC}     ${GRAY}(随机化, 握手时自动下发客户端, 无需客户端配置)${NC}"
            local pline
            while IFS= read -r pline; do
                [[ -n "$pline" ]] && echo -e "      ${GRAY}${pline}${NC}"
            done <<< "$at_pad_text"
        fi
        echo ""

        # AnyTLS IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}AnyTLS:${NC}"
            echo -e "  $(get_anytls_link "$SERVER_IPV4" "${hostname}_AnyTLS_v4")"
        fi

        # AnyTLS IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}AnyTLS:${NC}"
            echo -e "  $(get_anytls_link "$SERVER_IPV6" "${hostname}_AnyTLS_v6")"
        fi
    else
        # VLESS 节点显示
        # 根据协议类型显示端口（含传输层细节）
        if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
            echo -e "  ${BLUE}$(msg vision_port):${NC}  $PORT  ${GRAY}(network=tcp, flow=xtls-rprx-vision)${NC}"
        fi
        if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
            echo -e "  ${BLUE}$(msg xhttp_port):${NC}   $XHTTP_PORT  ${GRAY}(network=xhttp, path=${XHTTP_PATH:-/})${NC}"
        fi
        echo -e "  ${BLUE}UUID:${NC}        $UUID"
        echo -e "  ${BLUE}Security:${NC}    reality"
        echo -e "  ${BLUE}SNI:${NC}         $SNI"
        echo -e "  ${BLUE}PublicKey:${NC}   $PUBLIC_KEY"
        echo -e "  ${BLUE}ShortID:${NC}     $SHORT_ID"
        echo -e "  ${BLUE}Fingerprint:${NC} chrome"
        echo ""

        # IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]]; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            # Vision 链接
            if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
                echo -e "  ${YELLOW}Vision:${NC}"
                echo -e "  $(get_vision_link "$SERVER_IPV4" "${hostname}_Vision_v4")"
            fi
            # XHTTP 链接
            if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
                echo ""
                echo -e "  ${YELLOW}XHTTP:${NC}"
                echo -e "  $(get_xhttp_link "$SERVER_IPV4" "${hostname}_XHTTP_v4")"
            fi
        fi

        # IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            # Vision 链接
            if [[ "$proto_type" == "vision" || "$proto_type" == "both" ]] && [[ -n "${PORT:-}" ]]; then
                echo -e "  ${YELLOW}Vision:${NC}"
                echo -e "  $(get_vision_link "$SERVER_IPV6" "${hostname}_Vision_v6")"
            fi
            # XHTTP 链接
            if [[ "$proto_type" == "xhttp" || "$proto_type" == "both" ]] && [[ -n "${XHTTP_PORT:-}" ]]; then
                echo ""
                echo -e "  ${YELLOW}XHTTP:${NC}"
                echo -e "  $(get_xhttp_link "$SERVER_IPV6" "${hostname}_XHTTP_v6")"
            fi
        fi
    fi

    # 向后兼容：如果没有 IPv4/IPv6，使用旧的 SERVER_IP
    if [[ -z "${SERVER_IPV4:-}" ]] && [[ -z "${SERVER_IPV6:-}" ]] && [[ -n "${SERVER_IP:-}" ]]; then
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "${GREEN}$(msg share_link):${NC}"
        echo -e "${YELLOW}$(get_share_link)${NC}"
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

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

    # 在父 shell 里探测一次 Xray 能力并缓存；下面的 builder 都跑在命令替换的子 shell
    # 中，不预热的话每个 inbound 都会各自重新执行一次 `xray help`。
    xray_probe_capabilities

    for node_file in "$NODES_DIR"/*.env; do
        [[ -f "$node_file" ]] || continue

        # 使用安全的配置读取方式（防止命令注入）
        local n_name n_port n_uuid n_sni n_private_key n_short_id n_xhttp_port n_xhttp_path n_protocol_type
        local n_ss_method n_ss_password n_sid_list
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
        local n_extra_sids n_xhttp_uuid n_xhttp_private_key n_xhttp_sid_list n_mldsa65_seed n_decryption
        n_extra_sids=$(safe_read_config_value "$node_file" "EXTRA_SHORT_IDS")
        n_sid_list=$(reality_short_id_list "$n_short_id" "$n_extra_sids")

        # 处理可能加密的敏感值
        n_private_key=$(decrypt_value "$n_private_key")
        n_uuid=$(decrypt_value "$n_uuid")
        n_ss_password=$(decrypt_value "$n_ss_password")

        # both 节点的 XHTTP inbound 可以有独立的 UUID / REALITY 密钥 / shortId：两个
        # inbound 共用一套凭据时，其中一个被识别或泄露，另一个随之暴露。字段缺失
        # （升级前创建的节点）时回退到共用值，行为与之前完全一致。
        n_xhttp_uuid=$(decrypt_value "$(safe_read_config_value "$node_file" "XHTTP_UUID")")
        n_xhttp_private_key=$(decrypt_value "$(safe_read_config_value "$node_file" "XHTTP_PRIVATE_KEY")")
        n_xhttp_sid_list=$(safe_read_config_value "$node_file" "XHTTP_SHORT_ID")
        [[ -z "$n_xhttp_uuid" ]] && n_xhttp_uuid="$n_uuid"
        if [[ -z "$n_xhttp_private_key" ]]; then
            n_xhttp_private_key="$n_private_key"
            n_xhttp_sid_list="$n_sid_list"
        else
            n_xhttp_sid_list=$(reality_short_id_list "$n_xhttp_sid_list" "$n_extra_sids")
        fi

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

        # 可选的 REALITY ML-DSA-65 签名。节点启用了它而当前 binary 不认识该字段时
        # 必须失败：静默丢掉 seed 会让带 pqv 的客户端全部验签失败，且服务端毫无提示。
        n_mldsa65_seed=$(decrypt_value "$(safe_read_config_value "$node_file" "MLDSA65_SEED")")
        if [[ -n "$n_mldsa65_seed" ]] && ! xray_supports mldsa65; then
            log_error "$(t2 "节点 '$n_name' 启用了 REALITY ML-DSA-65，但当前 Xray 不支持，请先执行 xray-update" \
                "Node '$n_name' uses REALITY ML-DSA-65, which this Xray does not support; run xray-update first")"
            return 1
        fi

        # 可选的 VLESS Encryption，同样在核心不支持时失败而不是静默退回明文 VLESS。
        n_decryption=$(decrypt_value "$(safe_read_config_value "$node_file" "VLESS_DECRYPTION")")
        if [[ -n "$n_decryption" ]] && ! xray_supports vlessenc; then
            log_error "$(t2 "节点 '$n_name' 启用了 VLESS Encryption，但当前 Xray 不支持，请先执行 xray-update" \
                "Node '$n_name' uses VLESS Encryption, which this Xray does not support; run xray-update first")"
            return 1
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
            vision_inbound=$(build_vision_inbound "$n_name" "$validated_port" "$n_uuid" "$n_sni" "$n_private_key" "$n_sid_list" "$n_mldsa65_seed" "$n_decryption")
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
            xhttp_inbound=$(build_xhttp_inbound "$n_name" "$validated_xhttp_port" "$n_xhttp_uuid" "$n_sni" "$n_xhttp_private_key" "$n_xhttp_sid_list" "$n_xhttp_path" "$n_mldsa65_seed" "$n_decryption")
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

    # 构建 outbounds。freedom 的 domainStrategy 决定出站按哪个协议族解析域名：
    # 双栈档返回空串，不写该字段，保持 Xray 默认 AsIs 与既有安装完全一致。
    local outbounds_json freedom_strategy
    freedom_strategy=$(netstack_freedom_strategy)
    if ! outbounds_json=$(jq -n \
        --arg strategy "$freedom_strategy" \
        '[({"protocol": "freedom", "tag": "direct"}
            | if $strategy == "" then . else . + {"settings": {"domainStrategy": $strategy}} end),
          {"protocol": "blackhole", "tag": "block"}]' 2>&1); then
        log_error "Failed to build outbounds: $outbounds_json"
        return 1
    fi

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
        n_sid=$(reality_short_id_list "$(safe_read_config_value "$node_file" "SHORT_ID")" \
            "$(safe_read_config_value "$node_file" "EXTRA_SHORT_IDS")")
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
            local n_obfs
            n_obfs=$(decrypt_value "$(safe_read_config_value "$node_file" "HY2_OBFS_PASSWORD")")
            if ! inbound=$(build_hysteria2_inbound "$n_name" "$validated_port" "$n_pw" \
                "${n_sni:-www.bing.com}" "$cert_path" "$key_path" "$n_obfs"); then
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
    local save_ipv4="${SERVER_IPV4:-${SERVER_IP:-}}"
    local save_ipv6="${SERVER_IPV6:-}"

    # 所有字段一律使用 ${VAR:-} 展开。节点变量按协议部分赋值（AnyTLS 无 UUID、
    # Shadowsocks 无 REALITY 密钥……），在 `set -u` 下任何一个漏赋值的字段都会
    # 让安装在此处中断，且此时节点文件尚未落盘、服务也未配置。reset_node_state()
    # 已保证这些变量始终有定义，这里再兜一层，避免将来新增协议时重蹈覆辙。
    local save_uuid="${UUID:-}"
    local save_private_key="${PRIVATE_KEY:-}"
    local save_ss_password="${SS_PASSWORD:-}"
    local save_anytls_password="${ANYTLS_PASSWORD:-}"
    local save_hy2_password="${HY2_PASSWORD:-}"
    local save_xhttp_uuid="${XHTTP_UUID:-}"
    local save_xhttp_private_key="${XHTTP_PRIVATE_KEY:-}"
    local save_mldsa65_seed="${MLDSA65_SEED:-}"
    local save_vless_decryption="${VLESS_DECRYPTION:-}"
    local save_hy2_obfs_password="${HY2_OBFS_PASSWORD:-}"

    if is_encryption_enabled; then
        save_hy2_obfs_password=$(encrypt_value "$save_hy2_obfs_password")
        save_vless_decryption=$(encrypt_value "$save_vless_decryption")
        save_mldsa65_seed=$(encrypt_value "$save_mldsa65_seed")
        save_xhttp_uuid=$(encrypt_value "$save_xhttp_uuid")
        save_xhttp_private_key=$(encrypt_value "$save_xhttp_private_key")
        # encrypt_value 对空串直接返回空串，因此无需额外判空。
        save_uuid=$(encrypt_value "$save_uuid")
        save_private_key=$(encrypt_value "$save_private_key")
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
SNI=${SNI:-}
PUBLIC_KEY=${PUBLIC_KEY:-}
PRIVATE_KEY=$save_private_key
SHORT_ID=${SHORT_ID:-}
EXTRA_SHORT_IDS=${EXTRA_SHORT_IDS:-}
PROTOCOL_TYPE=${PROTOCOL_TYPE:-vision}
XHTTP_PORT=${XHTTP_PORT:-}
XHTTP_PATH=${XHTTP_PATH:-}
XHTTP_UUID=$save_xhttp_uuid
XHTTP_PUBLIC_KEY=${XHTTP_PUBLIC_KEY:-}
XHTTP_PRIVATE_KEY=$save_xhttp_private_key
XHTTP_SHORT_ID=${XHTTP_SHORT_ID:-}
MLDSA65_SEED=$save_mldsa65_seed
MLDSA65_VERIFY=${MLDSA65_VERIFY:-}
VLESS_DECRYPTION=$save_vless_decryption
VLESS_ENCRYPTION=${VLESS_ENCRYPTION:-}
SS_METHOD=${SS_METHOD:-}
SS_PASSWORD=$save_ss_password
ANYTLS_PASSWORD=$save_anytls_password
ANYTLS_PADDING_B64=${ANYTLS_PADDING_B64:-}
HY2_PASSWORD=$save_hy2_password
HY2_OBFS_PASSWORD=$save_hy2_obfs_password
ENV
    chmod 600 "$node_file"

    CURRENT_NODE_NAME="$node_name"
}

# 单链接与二维码使用的服务器地址：优先所选网络栈对应的协议族，其次回退到另一
# 族，最后回退到旧字段 SERVER_IP，保证升级前创建的节点文件仍能产出链接。
netstack_preferred_ip() {
    if [[ "$(netstack_mode)" == "v6" ]]; then
        printf '%s' "${SERVER_IPV6:-${SERVER_IPV4:-${SERVER_IP:-}}}"
    else
        printf '%s' "${SERVER_IPV4:-${SERVER_IPV6:-${SERVER_IP:-}}}"
    fi
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

    echo "vless://${UUID}@${ip_formatted}:${PORT}?encryption=${VLESS_ENCRYPTION:-none}&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}$(vless_link_pq_params)&type=tcp#${node_label}"
}

# VLESS 分享链接里的后量子参数。pqv 对应客户端的 mldsa65Verify（分享链接标准
# XTLS/Xray-core discussion #716），值是 base64url，无需转义。
vless_link_pq_params() {
    [[ -n "${MLDSA65_VERIFY:-}" ]] && printf '&pqv=%s' "$MLDSA65_VERIFY"
    return 0
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

    # 注意：XHTTP 不需要 flow 参数，path 需要 URL 编码。
    # mode=auto 显式写出：服务端 xhttpSettings 未限定模式（即 auto，接受全部上行
    # 方式），部分客户端在链接缺少 mode 时会自行猜一个固定模式。
    local encoded_path
    encoded_path=$(echo -n "$XHTTP_PATH" | sed 's|/|%2F|g')
    # both 节点拆分凭据后，XHTTP 链接使用自己的 UUID / 公钥 / shortId。
    local link_uuid="${XHTTP_UUID:-$UUID}" link_pbk="$PUBLIC_KEY" link_sid="$SHORT_ID"
    if [[ -n "${XHTTP_PUBLIC_KEY:-}" ]]; then
        link_pbk="$XHTTP_PUBLIC_KEY"
        link_sid="${XHTTP_SHORT_ID:-}"
    fi
    # 启用 VLESS Encryption 时 XHTTP 也使用 Vision 流控，链接需带上 flow。
    local link_flow=""
    [[ -n "${VLESS_ENCRYPTION:-}" ]] && link_flow="&flow=xtls-rprx-vision"
    echo "vless://${link_uuid}@${ip_formatted}:${XHTTP_PORT}?security=reality&encryption=${VLESS_ENCRYPTION:-none}${link_flow}&pbk=${link_pbk}&headerType=none&fp=chrome&type=xhttp&mode=auto&path=${encoded_path}&sni=${SNI}&sid=${link_sid}$(vless_link_pq_params)#${node_label}"
}

# ---- 后量子增强（可选） ----

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
    ( : >/dev/tty ) 2>/dev/null || return 0

    {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}        $(t2 "后量子增强（可选）" "Post-quantum options (optional)")${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}$(t2 "两项都要求较新的客户端；不确定客户端是否支持时请保持关闭。" \
        "Both need a recent client; leave them off when unsure about client support.")${NC}"
    echo ""
    echo -e "  ${GREEN}0.${NC} $(t2 "不启用（默认）" "Off (default)")"
    echo -e "  ${GREEN}1.${NC} VLESS Encryption  ${GRAY}(mlkem768x25519plus)${NC}"
    echo -e "  ${GREEN}2.${NC} REALITY ML-DSA-65  ${GRAY}($(t2 "证书后量子签名" "post-quantum certificate signature"))${NC}"
    echo -e "  ${GREEN}3.${NC} $(t2 "两项都启用" "Both")"
    echo ""
    echo -n "  $(t2 "请选择" "Select") [0-3] ($(t2 "默认" "default") 0): "
    } >/dev/tty

    local choice=""
    read -r choice </dev/tty || choice=""
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

# 为 both 节点的 XHTTP inbound 生成独立凭据（UUID + REALITY 密钥对 + shortId）。
# gen_reality_keys 直接写全局的 PUBLIC_KEY/PRIVATE_KEY/SHORT_ID，因此先保存 Vision
# 的那一套，生成后搬到 XHTTP_* 再还原。
gen_xhttp_credentials() {
    local keep_public="$PUBLIC_KEY" keep_private="$PRIVATE_KEY" keep_sid="$SHORT_ID" rc=0
    gen_reality_keys || rc=$?
    if ((rc == 0)); then
        XHTTP_PUBLIC_KEY="$PUBLIC_KEY"
        XHTTP_PRIVATE_KEY="$PRIVATE_KEY"
        XHTTP_SHORT_ID="$SHORT_ID"
        XHTTP_UUID=$(cat /proc/sys/kernel/random/uuid)
    fi
    PUBLIC_KEY="$keep_public"
    PRIVATE_KEY="$keep_private"
    SHORT_ID="$keep_sid"
    return "$rc"
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

# 自签名证书的 SHA-256 指纹（整张 DER 证书，小写十六进制，不含冒号）。
# 这与 Hysteria2 官方 URI 的 pinSHA256、Xray 的 pinnedPeerCertSha256 是同一种编码。
# Usage: cert_sha256_hex CERT_PEM
cert_sha256_hex() {
    local cert="$1" out
    [[ -s "$cert" ]] || return 1
    out=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null) || return 1
    out="${out##*=}"
    out="${out//:/}"
    out="${out,,}"
    [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$out"
}

# 证书公钥的 SHA-256（base64），对应 sing-box 出站的 certificate_public_key_sha256。
# Usage: cert_pubkey_sha256_b64 CERT_PEM
cert_pubkey_sha256_b64() {
    local cert="$1" out
    [[ -s "$cert" ]] || return 1
    out=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null | base64 -w0) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# 当前已加载节点的逐节点自签名证书路径。
node_selfsigned_cert_path() {
    printf '%s' "$SINGBOX_CERT_DIR/${NODE_NAME:-$CURRENT_NODE_NAME}.crt"
}

# 生成 Hysteria2 分享链接。密码被限制在 URI-unreserved 字符集内。
#
# 自签名证书下只给 insecure=1 已经不够：Xray 系客户端自 2026-06-01 起不再接受
# allowInsecure，必须改用证书指纹固定。链接因此同时携带 pinSHA256（Hysteria2 官方
# URI 参数）与 insecure=1：前者让支持固定的客户端真正校验这张证书，后者保留给只认
# insecure 的旧客户端。证书文件缺失时退回只带 insecure=1 的旧形式，不输出空指纹。
get_hy2_link() {
    local ip="$1"
    local node_label="$2"
    local ip_formatted="$ip"
    local pin="" query

    if [[ "$ip" == *:* ]]; then
        ip_formatted="[$ip]"
    fi

    query="sni=${SNI:-www.bing.com}&insecure=1"
    pin=$(cert_sha256_hex "$(node_selfsigned_cert_path)") || pin=""
    [[ -n "$pin" ]] && query+="&pinSHA256=${pin}"
    [[ -n "${HY2_OBFS_PASSWORD:-}" ]] && query+="&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}"

    echo "hysteria2://${HY2_PASSWORD}@${ip_formatted}:${PORT}/?${query}#${node_label}"
}

# 在节点信息里展示自签名证书指纹，供不支持从链接导入固定值的客户端手工填写。
show_selfsigned_cert_pins() {
    local cert pin_hex pin_key
    cert=$(node_selfsigned_cert_path)
    pin_hex=$(cert_sha256_hex "$cert") || return 0
    pin_key=$(cert_pubkey_sha256_b64 "$cert") || pin_key=""
    echo -e "  ${BLUE}Cert SHA-256:${NC} ${pin_hex}"
    echo -e "               ${GRAY}(Hysteria2 pinSHA256 / Xray pinnedPeerCertSha256)${NC}"
    if [[ -n "$pin_key" ]]; then
        echo -e "  ${BLUE}PubKey SHA-256:${NC} ${pin_key}"
        echo -e "               ${GRAY}(sing-box certificate_public_key_sha256)${NC}"
    fi
}

# 向后兼容的获取分享链接函数
get_share_link() {
    local node_file
    node_file=$(get_node_file "$CURRENT_NODE_NAME")
    # 使用安全的配置加载（防止命令注入）
    safe_load_node_config "$node_file"
    local node_label="${NODE_NAME:-RV-Reality}"
    local ip
    ip=$(netstack_preferred_ip)
    local proto_type="${PROTOCOL_TYPE:-vision}"

    # 根据协议类型返回对应的链接
    if [[ "$proto_type" == "hysteria2" ]] && [[ -n "${HY2_PASSWORD:-}" ]]; then
        HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")
        HY2_OBFS_PASSWORD=$(decrypt_value "${HY2_OBFS_PASSWORD:-}")
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
    local ip
    ip=$(netstack_preferred_ip)
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
    # 带 ML-DSA-65 公钥的链接接近 3KB：即使编码成功，二维码也大到终端里无法扫描。
    if (( ${#link} > 1200 )); then
        echo -e "  ${YELLOW}$(t2 "链接过长（${#link} 字符），不生成二维码，请复制下方链接导入" \
            "The link is too long for a scannable QR code (${#link} characters); copy the link below instead")${NC}"
    else
        qrencode -t ANSIUTF8 "$link"
    fi
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}$(msg share_link):${NC}"
    echo -e "${YELLOW}$link${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${MAGENTA}$(msg qr_tip)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# 附加 shortId 只在服务端白名单里，不进入分享链接，这里单独列出供手工发放。
show_extra_short_ids() {
    [[ -n "${EXTRA_SHORT_IDS:-}" ]] || return 0
    echo -e "  ${BLUE}Extra IDs:${NC}   ${EXTRA_SHORT_IDS//:/, }  ${GRAY}($(t2 "仅服务端白名单，可单独发放/吊销" "server allow-list only, hand out or revoke individually"))${NC}"
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
        if [[ -n "${SERVER_IPV4:-}" ]] && netstack_allows v4; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV4" "${hostname}_SS_v4")"
        fi

        # Shadowsocks IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]] && netstack_allows v6; then
            echo ""
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv6_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Shadowsocks:${NC}"
            echo -e "  $(get_ss_link "$SERVER_IPV6" "${hostname}_SS_v6")"
        fi
    elif [[ "$proto_type" == "hysteria2" ]]; then
        HY2_PASSWORD=$(decrypt_value "$HY2_PASSWORD")
        HY2_OBFS_PASSWORD=$(decrypt_value "${HY2_OBFS_PASSWORD:-}")
        echo -e "  ${BLUE}Port:${NC}        ${PORT:-N/A} (UDP/QUIC)"
        echo -e "  ${BLUE}Password:${NC}    ${HY2_PASSWORD:-N/A}"
        if [[ -n "$HY2_OBFS_PASSWORD" ]]; then
            echo -e "  ${BLUE}Obfs:${NC}        salamander  ${GRAY}(password: ${HY2_OBFS_PASSWORD})${NC}"
        fi
        echo -e "  ${BLUE}Transport:${NC}   Hysteria2 (sing-box)"
        echo -e "  ${BLUE}SNI:${NC}         ${SNI:-www.bing.com}"
        echo -e "  ${BLUE}Insecure:${NC}    true  ${GRAY}(self-signed certificate)${NC}"
        show_selfsigned_cert_pins
        echo ""

        if [[ -n "${SERVER_IPV4:-}" ]] && netstack_allows v4; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}Hysteria2:${NC}"
            echo -e "  $(get_hy2_link "$SERVER_IPV4" "${hostname}_Hysteria2_v4")"
        fi
        if [[ -n "${SERVER_IPV6:-}" ]] && netstack_allows v6; then
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
            show_extra_short_ids
            echo -e "  ${BLUE}Fingerprint:${NC} chrome"
        else
            echo -e "  ${BLUE}Security:${NC}    tls (self-signed)"
            echo -e "  ${BLUE}SNI:${NC}         ${SNI:-N/A}  ${GRAY}(证书 CN / cert CN)${NC}"
            echo -e "  ${BLUE}Insecure:${NC}    true  ${GRAY}(客户端需允许不安全连接)${NC}"
            show_selfsigned_cert_pins
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
        if [[ -n "${SERVER_IPV4:-}" ]] && netstack_allows v4; then
            echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
            echo -e "${GREEN}$(msg ipv4_links):${NC}"
            echo ""
            echo -e "  ${YELLOW}AnyTLS:${NC}"
            echo -e "  $(get_anytls_link "$SERVER_IPV4" "${hostname}_AnyTLS_v4")"
        fi

        # AnyTLS IPv6 链接
        if [[ -n "${SERVER_IPV6:-}" ]] && netstack_allows v6; then
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
        show_extra_short_ids
        if [[ -n "${MLDSA65_VERIFY:-}" ]]; then
            echo -e "  ${BLUE}ML-DSA-65:${NC}   $(t2 "已启用（客户端 mldsa65Verify 见分享链接 pqv）" "enabled (client mldsa65Verify is the pqv link parameter)")"
        fi
        if [[ -n "${VLESS_ENCRYPTION:-}" ]]; then
            echo -e "  ${BLUE}Encryption:${NC}  ${VLESS_ENCRYPTION%.*}.<key>  ${GRAY}(VLESS Encryption)${NC}"
        fi
        if [[ "$proto_type" == "both" && -n "${XHTTP_PUBLIC_KEY:-}" ]]; then
            echo -e "  ${BLUE}XHTTP UUID:${NC}  ${XHTTP_UUID:-$UUID}  ${GRAY}($(t2 "XHTTP 使用独立凭据" "XHTTP has its own credentials"))${NC}"
            echo -e "  ${BLUE}XHTTP PubKey:${NC} $XHTTP_PUBLIC_KEY"
            echo -e "  ${BLUE}XHTTP ShortID:${NC} ${XHTTP_SHORT_ID:-}"
        fi
        echo -e "  ${BLUE}Fingerprint:${NC} chrome"
        echo ""

        # IPv4 链接
        if [[ -n "${SERVER_IPV4:-}" ]] && netstack_allows v4; then
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
        if [[ -n "${SERVER_IPV6:-}" ]] && netstack_allows v6; then
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

    # 向后兼容：上面没有输出任何协议族链接时回退到单链接。除了"旧节点只有
    # SERVER_IP"，这里还覆盖"节点记录的地址族与当前网络栈设置不一致"（例如把
    # 网络栈切到 v6 后查看一个只记录了 IPv4 的旧节点），否则该节点会一条链接都没有。
    if ! { [[ -n "${SERVER_IPV4:-}" ]] && netstack_allows v4; } \
        && ! { [[ -n "${SERVER_IPV6:-}" ]] && netstack_allows v6; } \
        && [[ -n "${SERVER_IP:-}" ]]; then
        echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
        echo -e "${GREEN}$(msg share_link):${NC}"
        echo -e "${YELLOW}$(get_share_link)${NC}"
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

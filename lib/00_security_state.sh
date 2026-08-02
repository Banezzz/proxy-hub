# ============== 单实例锁机制 ==============
LOCK_PARENT=""
LOCK_DIR=""
PID_FILE=""
LOCK_OWNER_FILE=""
LOCK_FILE=""
LOCK_FD=200
LOCK_HELD_METHOD=""
LOCK_TOKEN=""
LOCK_DIR_ID=""
LOCK_SIGNAL_PENDING=""
LOCK_BOOT_ID_PATH="/proc/sys/kernel/random/boot_id"

lock_prepare_parent() {
    local base_dir="/tmp" base_mode base_owner mode owner

    [[ -d "$base_dir" && ! -L "$base_dir" && -w "$base_dir" ]] || return 1
    base_owner=$(stat -c '%u' "$base_dir" 2>/dev/null) || return 1
    base_mode=$(stat -c '%a' "$base_dir" 2>/dev/null) || return 1
    [[ "$base_mode" =~ ^[0-7]+$ ]] || return 1
    if [[ "$base_owner" == "$EUID" ]] && (( (8#$base_mode & 022) == 0 )); then
        :
    elif [[ "$base_owner" == "0" ]] && (( (8#$base_mode & 01000) != 0 )); then
        :
    else
        return 1
    fi

    LOCK_PARENT="${base_dir%/}/proxy-hub-${EUID}"
    if [[ ! -e "$LOCK_PARENT" ]]; then
        (umask 077; mkdir -m 700 "$LOCK_PARENT") 2>/dev/null || return 1
    fi

    [[ -d "$LOCK_PARENT" && ! -L "$LOCK_PARENT" ]] || return 1
    owner=$(stat -c '%u' "$LOCK_PARENT" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$LOCK_PARENT" 2>/dev/null) || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 077) == 0 )) || return 1

    LOCK_DIR="$LOCK_PARENT/write.lock.d"
    PID_FILE="$LOCK_DIR/pid"
    LOCK_OWNER_FILE="$LOCK_DIR/owner"
    LOCK_FILE=""
}

lock_dir_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null
}

# Start time (field 22 of /proc/<pid>/stat) of a process.  A PID alone is not an
# identity because the kernel recycles it; PID plus start time is, so recording
# it lets a later run tell "the owner is still running" apart from "an unrelated
# process now happens to own that PID".  The build script's release lock uses
# the same field for the same reason.  Process state is deliberately not
# filtered here: this answers "which process is this", not "is it healthy".
lock_process_start_time() {
    local pid="$1" stat_line rest
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
    rest="${stat_line##*) }"
    [[ "$rest" != "$stat_line" ]] || return 1
    # shellcheck disable=SC2086 # deliberate word splitting of /proc stat fields
    set -- $rest
    (($# >= 20)) || return 1
    [[ "${20}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${20}"
}

# Boot id of the running kernel.  Start times are counted from boot, so they are
# only comparable within one boot; recording the boot id makes a lock that
# survived a reboot provably stale even when /tmp was not cleared.
lock_boot_id() {
    local boot_id=""
    [[ -r "$LOCK_BOOT_ID_PATH" ]] || return 1
    IFS= read -r boot_id < "$LOCK_BOOT_ID_PATH" 2>/dev/null || return 1
    [[ "$boot_id" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || return 1
    printf '%s\n' "$boot_id"
}

lock_acquire() {
    local candidate_token dir_id="" pending_signal rc=1 saved_int saved_term

    [[ -z "$LOCK_HELD_METHOD" ]] || return 1
    lock_prepare_parent || return 1
    candidate_token="${EUID}-$$-${RANDOM}-${RANDOM}"

    LOCK_SIGNAL_PENDING=""
    saved_int=$(trap -p INT || true)
    saved_term=$(trap -p TERM || true)
    trap 'LOCK_SIGNAL_PENDING=INT' INT
    trap 'LOCK_SIGNAL_PENDING=TERM' TERM

    if dir_id=$(
        local owner_tmp="$LOCK_DIR/.owner-${candidate_token}"
        local pid_tmp="$LOCK_DIR/.pid-${candidate_token}"
        local candidate_id=""
        local owner_start="" owner_boot=""

        trap '' INT TERM
        umask 077

        cleanup_candidate() {
            if [[ -n "$candidate_id" && -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] \
                && [[ "$(lock_dir_identity "$LOCK_DIR")" == "$candidate_id" ]]; then
                [[ -f "$owner_tmp" && ! -L "$owner_tmp" ]] && rm -f -- "$owner_tmp"
                [[ -f "$pid_tmp" && ! -L "$pid_tmp" ]] && rm -f -- "$pid_tmp"
                [[ -f "$LOCK_OWNER_FILE" && ! -L "$LOCK_OWNER_FILE" ]] && rm -f -- "$LOCK_OWNER_FILE"
                [[ -f "$PID_FILE" && ! -L "$PID_FILE" ]] && rm -f -- "$PID_FILE"
                rmdir "$LOCK_DIR" 2>/dev/null || true
            fi
        }

        mkdir "$LOCK_DIR" 2>/dev/null || exit 1
        candidate_id=$(lock_dir_identity "$LOCK_DIR") || {
            cleanup_candidate
            exit 1
        }
        printf '%s\n%s\n' "$candidate_token" "$$" > "$owner_tmp" || {
            cleanup_candidate
            exit 1
        }
        [[ -f "$owner_tmp" && ! -L "$owner_tmp" ]] || {
            cleanup_candidate
            exit 1
        }
        mv -- "$owner_tmp" "$LOCK_OWNER_FILE" || {
            cleanup_candidate
            exit 1
        }
        # Owner identity: PID, its start time and the boot id.  The extra lines
        # are optional metadata—readers fall back to PID-only classification
        # when they are absent or unparseable.
        owner_start=$(lock_process_start_time "$$" 2>/dev/null) || owner_start=""
        owner_boot=$(lock_boot_id 2>/dev/null) || owner_boot=""
        printf '%s\n%s\n%s\n' "$$" "$owner_start" "$owner_boot" > "$pid_tmp" || {
            cleanup_candidate
            exit 1
        }
        [[ -f "$pid_tmp" && ! -L "$pid_tmp" ]] || {
            cleanup_candidate
            exit 1
        }
        mv -- "$pid_tmp" "$PID_FILE" || {
            cleanup_candidate
            exit 1
        }
        printf '%s\n' "$candidate_id"
    ); then
        LOCK_TOKEN="$candidate_token"
        LOCK_DIR_ID="$dir_id"
        LOCK_HELD_METHOD="mkdir"
        rc=0
    fi

    if [[ -n "$saved_int" ]]; then eval "$saved_int"; else trap - INT; fi
    if [[ -n "$saved_term" ]]; then eval "$saved_term"; else trap - TERM; fi
    pending_signal="$LOCK_SIGNAL_PENDING"
    LOCK_SIGNAL_PENDING=""
    if [[ -n "$pending_signal" ]]; then
        kill -s "$pending_signal" "$$" 2>/dev/null || true
    fi
    return "$rc"
}

lock_release() {
    local owner_token=""

    [[ "$LOCK_HELD_METHOD" == "mkdir" && -n "$LOCK_DIR_ID" && -n "$LOCK_TOKEN" ]] || return 0
    [[ -d "$LOCK_DIR" && ! -L "$LOCK_DIR" ]] || return 0
    [[ "$(lock_dir_identity "$LOCK_DIR")" == "$LOCK_DIR_ID" ]] || return 0
    [[ -f "$LOCK_OWNER_FILE" && ! -L "$LOCK_OWNER_FILE" ]] || return 0
    IFS= read -r owner_token < "$LOCK_OWNER_FILE" || return 0
    [[ "$owner_token" == "$LOCK_TOKEN" ]] || return 0

    [[ ! -e "$PID_FILE" || ( -f "$PID_FILE" && ! -L "$PID_FILE" ) ]] || return 0
    rm -f -- "$PID_FILE" "$LOCK_OWNER_FILE" 2>/dev/null || return 0
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD_METHOD=""
    LOCK_TOKEN=""
    LOCK_DIR_ID=""
}

# ---------------- Stale-lock diagnostics (read-only) ----------------
# These helpers never modify, remove, or steal the lock. Per docs/audits.md the
# lock is deliberately not auto-reclaimed from PID metadata (PID reuse / forged
# metadata risk); they only let a caller tell a human whether the recorded owner
# is still alive, so manual recovery becomes a single obvious command.

# Print the PID recorded in the current lock, or return non-zero when the lock
# metadata is missing, unreadable, a symlink, or malformed.
lock_recorded_pid() {
    local pid=""
    [[ -n "${PID_FILE:-}" && -f "$PID_FILE" && ! -L "$PID_FILE" ]] || return 1
    IFS= read -r pid < "$PID_FILE" 2>/dev/null || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

# Print the owner start time recorded next to the PID, or return non-zero when
# the lock predates this metadata or records it in an unusable form.
lock_recorded_start() {
    local pid="" start=""
    [[ -n "${PID_FILE:-}" && -f "$PID_FILE" && ! -L "$PID_FILE" ]] || return 1
    { IFS= read -r pid && IFS= read -r start; } < "$PID_FILE" 2>/dev/null || return 1
    [[ "$start" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$start"
}

# Print the boot id recorded next to the PID, with the same fallback contract.
lock_recorded_boot_id() {
    local pid="" start="" boot=""
    [[ -n "${PID_FILE:-}" && -f "$PID_FILE" && ! -L "$PID_FILE" ]] || return 1
    { IFS= read -r pid && IFS= read -r start && IFS= read -r boot; } \
        < "$PID_FILE" 2>/dev/null || return 1
    [[ "$boot" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || return 1
    printf '%s\n' "$boot"
}

# Whether a PID currently exists at all (used only to word the stale-lock hint).
lock_pid_present() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ -d /proc/self ]]; then
        [[ -e "/proc/$pid" ]]
        return
    fi
    kill -0 "$pid" 2>/dev/null
}

# Classify a recorded owner without touching the lock:
#   0 -> still alive (a real instance may be running)
#   1 -> provably gone (the lock is stale)
#   2 -> liveness cannot be determined; treat conservatively as maybe-alive
# The optional start time and boot id are the ones recorded when the lock was
# taken.  With them a recycled PID—the same number reused by an unrelated
# process, which used to read as "another instance is running" forever—is
# classified as stale instead.
lock_pid_liveness() {
    local pid="${1:-}" recorded_start="${2:-}" recorded_boot="${3:-}"
    local actual_start="" boot_id=""

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2

    # A lock written before the current boot cannot have a live owner.
    if [[ "$recorded_boot" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]]; then
        boot_id=$(lock_boot_id 2>/dev/null) || boot_id=""
        [[ -z "$boot_id" || "$boot_id" == "$recorded_boot" ]] || return 1
    fi

    [[ "$pid" == "$$" ]] && return 0
    if [[ -d /proc/self ]]; then
        [[ -e "/proc/$pid" ]] || return 1
        [[ "$recorded_start" =~ ^[0-9]+$ ]] || return 0
        actual_start=$(lock_process_start_time "$pid" 2>/dev/null) || return 2
        [[ "$actual_start" == "$recorded_start" ]] || return 1
        return 0
    fi
    kill -0 "$pid" 2>/dev/null && return 0
    return 2
}

# ============== Security Helper Functions ==============

# Compatibility names intentionally use the same mkdir exclusion domain. A
# separate flock file would allow mixed-mode processes to write concurrently.
lock_acquire_flock() {
    lock_acquire
}

lock_release_flock() {
    lock_release
}

# All current entry points acquire the same private mkdir lock.
lock_acquire_smart() {
    lock_acquire
}

lock_release_smart() {
    lock_release
}

# Secure curl wrapper with TLS enforcement and redirect limits
# Usage: secure_curl [curl_options] URL
secure_curl() {
    curl --proto '=https' --tlsv1.2 --max-redirs 3 -fsSL "$@"
}

# Safe download with optional SHA256 verification
# Usage: safe_download_and_verify URL DEST_FILE [EXPECTED_SHA256]
# Returns: 0 on success, 1 on download failure, 2 on checksum mismatch
safe_download_and_verify() {
    local url="$1"
    local dest="$2"
    local expected_sha="${3:-}"

    # Download file
    if ! secure_curl "$url" -o "$dest" 2>/dev/null; then
        return 1
    fi

    # Verify checksum if provided
    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        actual_sha=$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            log_warn "Checksum mismatch for $url"
            log_warn "Expected: $expected_sha"
            log_warn "Got: $actual_sha"
            return 2
        fi
    fi

    return 0
}

# Fetch GitHub release tag using jq instead of grep/cut
# Usage: fetch_github_release_tag REPO
fetch_github_release_tag() {
    local repo="$1"
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local response

    response=$(secure_curl "$api_url" 2>/dev/null) || return 1

    # Use jq for safe JSON parsing
    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.tag_name // empty' 2>/dev/null
    else
        # Fallback: careful grep (less safe but functional)
        echo "$response" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1
    fi
}

# Safe config value extraction (prevents command injection)
# Usage: safe_read_config_value FILE KEY
# Returns the value or empty string if not found/invalid
safe_read_config_value() {
    local file="$1"
    local key="$2"
    local value=""

    [[ ! -f "$file" ]] && return 1

    # Read line matching KEY= pattern
    # Note: Cannot use IFS='=' because values may contain '=' (e.g., base64 padding)
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip trailing CR (handles CRLF files / xray output with \r)
        line="${line%$'\r'}"

        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue

        # Extract key (everything before first '=')
        local k="${line%%=*}"
        # Extract value (everything after first '=')
        local v="${line#*=}"

        # Match exact key
        if [[ "$k" == "$key" ]]; then
            # Trim leading/trailing whitespace defensively
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"

            # Security: reject values containing dangerous characters
            # Allow: alphanumeric, dash, underscore, dot, slash, colon, equals, plus, at, brackets
            # Reject: backticks, $, ;, |, &, newlines, etc.
            # Note: In POSIX regex, ] must be first if included, - must be last or first
            if [[ "$v" =~ ^[]a-zA-Z0-9_./:=+@[-]*$ ]]; then
                value="$v"
            else
                # Log warning but don't fail (backward compat)
                log_warn "Potentially unsafe value for $key in $file, using empty"
                value=""
            fi
            break
        fi
    done < "$file"

    echo "$value"
}

# 节点作用域全局变量的唯一权威清单。
#
# 程序以 `set -u` 运行，因此任何一个未被赋值的变量在展开时都会立刻终止整个脚本。
# 各协议分支只会赋值它自己用得到的字段（例如 AnyTLS 不需要 UUID，Shadowsocks
# 不需要 REALITY 密钥），所以必须有一个统一的地方把全部字段都置为已定义状态，
# 否则某个协议路径漏掉一个字段就会在 save_env 等下游函数里炸掉。
#
# 同样重要的是：这些变量是进程级全局量。同一次菜单会话里连续安装两个节点时，
# 若不重置，第二个节点会继承第一个节点残留的密钥/端口，把不属于它的凭据写进
# 自己的 .env。因此 install_node 也必须在进入协议分支之前调用本函数。
# 注意：CURRENT_NODE_NAME 不在此列表内。它表示“当前选中的节点”，由 select_node /
# install_node 在读取配置之前设置，属于选择状态而非节点内容；清空它会让随后的
# save_env 回退到 ${CURRENT_NODE_NAME:-$PORT} 并写错文件。
reset_node_state() {
    NODE_NAME="" PORT="" UUID="" SNI=""
    PUBLIC_KEY="" PRIVATE_KEY="" SHORT_ID=""
    XHTTP_PORT="" XHTTP_PATH=""
    SERVER_IP="" SERVER_IPV4="" SERVER_IPV6=""
    SS_METHOD="" SS_PASSWORD=""
    ANYTLS_PASSWORD="" ANYTLS_PADDING_B64=""
    HY2_PASSWORD=""
    PROTOCOL_TYPE="vision"
}

# 在模块加载时就建立一次基线，使得任何代码路径（包括从未选择过协议的只读命令）
# 展开上述变量时都不会触发 unbound variable。
reset_node_state

# Safe load all config values from node file
# Usage: safe_load_node_config FILE
# Sets variables: NODE_NAME, PORT, UUID, SNI, PUBLIC_KEY, PRIVATE_KEY, SHORT_ID,
#                 PROTOCOL_TYPE, XHTTP_PORT, XHTTP_PATH, SERVER_IP, SERVER_IPV4, SERVER_IPV6,
#                 SS_METHOD, SS_PASSWORD, ANYTLS_PASSWORD, HY2_PASSWORD
safe_load_node_config() {
    local file="$1"

    [[ ! -f "$file" ]] && return 1

    # Reset all variables first
    reset_node_state
    # 本函数按文件内容重新填充；缺失的键保持空值，因此协议类型也从空开始判断。
    PROTOCOL_TYPE=""

    # Load each value safely
    NODE_NAME=$(safe_read_config_value "$file" "NODE_NAME")
    PORT=$(safe_read_config_value "$file" "PORT")
    UUID=$(safe_read_config_value "$file" "UUID")
    SNI=$(safe_read_config_value "$file" "SNI")
    PUBLIC_KEY=$(safe_read_config_value "$file" "PUBLIC_KEY")
    PRIVATE_KEY=$(safe_read_config_value "$file" "PRIVATE_KEY")
    SHORT_ID=$(safe_read_config_value "$file" "SHORT_ID")
    PROTOCOL_TYPE=$(safe_read_config_value "$file" "PROTOCOL_TYPE")
    XHTTP_PORT=$(safe_read_config_value "$file" "XHTTP_PORT")
    XHTTP_PATH=$(safe_read_config_value "$file" "XHTTP_PATH")
    SERVER_IP=$(safe_read_config_value "$file" "SERVER_IP")
    SERVER_IPV4=$(safe_read_config_value "$file" "SERVER_IPV4")
    SERVER_IPV6=$(safe_read_config_value "$file" "SERVER_IPV6")
    SS_METHOD=$(safe_read_config_value "$file" "SS_METHOD")
    SS_PASSWORD=$(safe_read_config_value "$file" "SS_PASSWORD")
    ANYTLS_PASSWORD=$(safe_read_config_value "$file" "ANYTLS_PASSWORD")
    HY2_PASSWORD=$(safe_read_config_value "$file" "HY2_PASSWORD")

    return 0
}

# Validate and extract port number (strips non-numeric, validates range)
# Usage: get_validated_port RAW_PORT [SILENT]
# Returns: validated port number or empty string
get_validated_port() {
    local raw_port="$1"
    local silent="${2:-false}"

    # Strip any non-numeric characters (security hardening)
    local port="${raw_port//[^0-9]/}"

    # Validate range
    if [[ -z "$port" ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        [[ "$silent" != "true" ]] && log_error "Invalid port: $raw_port"
        return 1
    fi

    echo "$port"
}

# ============== 网络栈（IPv4 / IPv6）选择 ==============
#
# Linux 上 Xray 与 sing-box 的通配监听地址默认就是双栈：Go 监听通配地址且 network
# 为 "tcp" 时会创建未设置 IPV6_V6ONLY 的 AF_INET6 socket，因此 "0.0.0.0" 与 "::"
# 等价（Xray 文档同样如此说明）。本设置要解决的不是"能否收到 IPv6 连接"，而是
# 现有实现无法表达的三件事：
#   1. 严格只收 IPv6（需要 streamSettings.sockopt.v6only，Xray 转成 IPV6_V6ONLY）；
#   2. 出站按指定协议族解析域名（freedom 的 domainStrategy）；
#   3. SNI 测速、服务器 IP 探测与分享链接只使用被选中的协议族。
#
# 双栈档刻意保留 "0.0.0.0" 而不改写成 "::"：内核以 ipv6.disable=1 启动时 bind "::"
# 会直接失败，"0.0.0.0" 不会，默认档必须对现有安装零回归。
# 同理，v4 档也只能停在通配地址：真正的 v4-only 监听要求 bind 具体网卡地址，而
# NAT 型云主机上公网地址并不在网卡上，bind 它会让服务起不来。该边界记录在
# docs/audits.md。
NETSTACK_FILE="/root/.proxy_hub_netstack"

netstack_is_valid() {
    case "${1:-}" in
        dual|v4|v6) return 0 ;;
        *) return 1 ;;
    esac
}

# 把用户输入（ipstack= 环境变量）规范成 dual/v4/v6；无法识别时返回非零，
# 绝不把原值直接落盘或拼进配置。
netstack_normalize() {
    local raw="${1:-}"
    raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]_-')
    case "$raw" in
        dual|both|v4v6|ipv4ipv6|46) printf 'dual' ;;
        v4|ipv4|4|v4only|ipv4only) printf 'v4' ;;
        v6|ipv6|6|v6only|ipv6only) printf 'v6' ;;
        *) return 1 ;;
    esac
}

# 读取持久化设置；文件缺失、为空、是符号链接或内容非法时一律回退到 dual。
netstack_mode() {
    local mode=""
    if [[ -f "$NETSTACK_FILE" && ! -L "$NETSTACK_FILE" ]]; then
        read -r mode < "$NETSTACK_FILE" 2>/dev/null || mode=""
        mode="${mode//[^a-z0-9]/}"
    fi
    netstack_is_valid "$mode" || mode="dual"
    printf '%s' "$mode"
}

netstack_save() {
    local mode="${1:-}"
    netstack_is_valid "$mode" || return 1
    printf '%s\n' "$mode" > "$NETSTACK_FILE" || return 1
    chmod 600 "$NETSTACK_FILE" 2>/dev/null || true
}

# 某个协议族是否参与本次配置（IP 探测、分享链接、二维码）。
netstack_allows() {
    local family="${1:-}"
    case "$(netstack_mode)" in
        v4) [[ "$family" == "v4" ]] ;;
        v6) [[ "$family" == "v6" ]] ;;
        *) [[ "$family" == "v4" || "$family" == "v6" ]] ;;
    esac
}

# Xray inbound 的监听地址。
netstack_listen_addr() {
    if [[ "$(netstack_mode)" == "v6" ]]; then
        printf '::'
    else
        printf '0.0.0.0'
    fi
}

# sing-box inbound 的监听地址。两个内核在 dual 档各自保留自己的历史写法
# （Xray "0.0.0.0"、sing-box "::"）：它们在通配地址上等价，改写只会给现有
# AnyTLS / Hysteria2 安装引入一次无收益的行为变更。只有 v4 档需要落到 IPv4
# 通配地址，好让"只用 IPv4"这个选择在两个内核里表达一致。
netstack_singbox_listen_addr() {
    if [[ "$(netstack_mode)" == "v4" ]]; then
        printf '0.0.0.0'
    else
        printf '::'
    fi
}

# 只有 v6 档需要 sockopt.v6only；其余档返回 JSON null，jq 侧不写出该字段。
# 该选项只存在于 Xray；sing-box inbound 没有等价字段，因此 AnyTLS 与 Hysteria2
# 在 v6 档下仍是绑定 "::" 的双栈 socket，只是不再产出 IPv4 分享链接。
netstack_sockopt_json() {
    if [[ "$(netstack_mode)" == "v6" ]]; then
        printf '{"v6only":true}'
    else
        printf 'null'
    fi
}

# freedom 出站的 domainStrategy。双栈档返回空串，保持 Xray 默认的 AsIs 与既有
# 行为一致；v4/v6 档只使用自 V2Ray 时代就存在的 UseIPv4/UseIPv6，避免较旧的
# Xray binary 在 `xray -test` 阶段拒绝 UseIPv4v6 这类新枚举值。
netstack_freedom_strategy() {
    case "$(netstack_mode)" in
        v4) printf 'UseIPv4' ;;
        v6) printf 'UseIPv6' ;;
        *) printf '' ;;
    esac
}

# openssl s_client 的协议族参数（SNI 测速与自定义 SNI 连通性检查）。
# 返回空串表示跟随系统解析顺序。调用方须用 ${arr[@]+"${arr[@]}"} 展开，
# 因为 bash 4.2 在 `set -u` 下展开空数组会报 unbound variable。
netstack_openssl_family() {
    case "$(netstack_mode)" in
        v4) printf '%s' '-4' ;;
        v6) printf '%s' '-6' ;;
        *) printf '' ;;
    esac
}

# Build Vision inbound JSON using jq (prevents injection)
# Usage: build_vision_inbound NAME PORT UUID SNI PRIVATE_KEY SHORT_ID
build_vision_inbound() {
    local name="$1"
    local port="$2"
    local uuid="$3"
    local sni="$4"
    local private_key="$5"
    local short_id="$6"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_vision" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --arg listen "$(netstack_listen_addr)" \
        --argjson sockopt "$(netstack_sockopt_json)" \
        '{
            "tag": $tag,
            "listen": $listen,
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": ({
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "\($sni):443",
                    "serverNames": [$sni],
                    "privateKey": $private_key,
                    "shortIds": [$short_id],
                    "fingerprint": "chrome"
                }
            } | if $sockopt then . + {"sockopt": $sockopt} else . end),
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Build XHTTP inbound JSON using jq (prevents injection)
# Usage: build_xhttp_inbound NAME PORT UUID SNI PRIVATE_KEY SHORT_ID PATH
build_xhttp_inbound() {
    local name="$1"
    local port="$2"
    local uuid="$3"
    local sni="$4"
    local private_key="$5"
    local short_id="$6"
    local xhttp_path="$7"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_xhttp" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --arg path "$xhttp_path" \
        --arg listen "$(netstack_listen_addr)" \
        --argjson sockopt "$(netstack_sockopt_json)" \
        '{
            "tag": $tag,
            "listen": $listen,
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": ""}],
                "decryption": "none"
            },
            "streamSettings": ({
                "network": "xhttp",
                "security": "reality",
                "xhttpSettings": {"path": $path},
                "realitySettings": {
                    "show": false,
                    "dest": "\($sni):443",
                    "serverNames": [$sni],
                    "privateKey": $private_key,
                    "shortIds": [$short_id],
                    "fingerprint": "chrome"
                }
            } | if $sockopt then . + {"sockopt": $sockopt} else . end),
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        }'
}

# Build Shadowsocks inbound JSON using jq (prevents injection)
# Usage: build_shadowsocks_inbound NAME PORT METHOD PASSWORD
build_shadowsocks_inbound() {
    local name="$1"
    local port="$2"
    local method="$3"
    local password="$4"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    jq -n \
        --arg tag "${name}_ss" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        --arg listen "$(netstack_listen_addr)" \
        --argjson sockopt "$(netstack_sockopt_json)" \
        '{
            "tag": $tag,
            "listen": $listen,
            "port": $port,
            "protocol": "shadowsocks",
            "settings": {
                "method": $method,
                "password": $password,
                "network": "tcp,udp"
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
        } | if $sockopt then . + {"streamSettings": {"sockopt": $sockopt}} else . end'
}

# Build AnyTLS inbound JSON (sing-box) using jq (prevents injection)
# Usage: build_anytls_inbound NAME PORT PASSWORD PADDING MODE SNI PRIVKEY SHORTID CERT KEY
#   MODE = reality | tls
#   For MODE=reality: SNI/PRIVKEY/SHORTID required, CERT/KEY ignored
#   For MODE=tls:     SNI/CERT/KEY required (self-signed), PRIVKEY/SHORTID ignored
build_anytls_inbound() {
    local name="$1"
    local port="$2"
    local password="$3"
    local padding="$4"
    local mode="$5"
    local sni="$6"
    local privkey="$7"
    local shortid="$8"
    local cert="$9"
    local key="${10}"

    # Validate port
    port=$(get_validated_port "$port" true) || return 1

    # 构建 TLS 块（reality 伪装 或 自签名证书）
    local tls_json
    if [[ "$mode" == "reality" ]]; then
        tls_json=$(jq -n \
            --arg sni "$sni" \
            --arg priv "$privkey" \
            --arg sid "$shortid" \
            '{
                "enabled": true,
                "server_name": $sni,
                "reality": {
                    "enabled": true,
                    "handshake": {"server": $sni, "server_port": 443},
                    "private_key": $priv,
                    "short_id": [$sid]
                }
            }') || return 1
    else
        tls_json=$(jq -n \
            --arg sni "$sni" \
            --arg cert "$cert" \
            --arg key "$key" \
            '{
                "enabled": true,
                "server_name": $sni,
                "certificate_path": $cert,
                "key_path": $key
            }') || return 1
    fi

    # padding scheme 为字符串数组（每行一条规则）；服务端会在握手时
    # 通过 cmdUpdatePaddingScheme 自动下发给客户端，无需客户端额外配置。
    jq -n \
        --arg tag "${name}_anytls" \
        --argjson port "$port" \
        --arg name "$name" \
        --arg password "$password" \
        --arg padding "$padding" \
        --argjson tls "$tls_json" \
        --arg listen "$(netstack_singbox_listen_addr)" \
        '{
            "type": "anytls",
            "tag": $tag,
            "listen": $listen,
            "listen_port": $port,
            "users": [{"name": $name, "password": $password}],
            "padding_scheme": ($padding | split("\n") | map(select(length > 0))),
            "tls": $tls
        }'
}

# Validate a TLS server name before it is written to JSON or a share URI.
# IPv4 literals are accepted; empty labels, URI delimiters, and overlong labels
# are rejected. Hysteria2 uses this value as TLS SNI, so IPv6 literals are not
# accepted here.
validate_tls_server_name() {
    local value="${1:-}"
    local label
    local -a labels=()

    [[ -n "$value" && ${#value} -le 253 ]] || return 1
    [[ "$value" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1

    IFS='.' read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

# Build a Hysteria2 inbound for sing-box using jq (prevents JSON injection).
# Usage: build_hysteria2_inbound NAME PORT PASSWORD SNI CERT KEY
build_hysteria2_inbound() {
    local name="$1"
    local port="$2"
    local password="$3"
    local sni="$4"
    local cert="$5"
    local key="$6"

    port=$(get_validated_port "$port" true) || return 1
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$password" =~ ^[a-zA-Z0-9._~-]{8,128}$ ]] || return 1
    validate_tls_server_name "$sni" || return 1
    [[ -n "$cert" && -n "$key" ]] || return 1

    jq -n \
        --arg tag "${name}_hysteria2" \
        --argjson port "$port" \
        --arg name "$name" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg cert "$cert" \
        --arg key "$key" \
        --arg listen "$(netstack_singbox_listen_addr)" \
        '{
            "type": "hysteria2",
            "tag": $tag,
            "listen": $listen,
            "listen_port": $port,
            "users": [{"name": $name, "password": $password}],
            "tls": {
                "enabled": true,
                "server_name": $sni,
                "certificate_path": $cert,
                "key_path": $key
            },
            "masquerade": {
                "type": "proxy",
                "url": "https://www.bing.com",
                "rewrite_host": true
            }
        }'
}

# Optional encryption for sensitive config values
# Usage: encrypt_value PLAINTEXT
# Returns: base64-encoded encrypted value with "U2FsdGVk" prefix (OpenSSL magic)
ENCRYPTION_KEY_FILE="/root/.reality_vision_key"

setup_encryption_key() {
    if [[ ! -f "$ENCRYPTION_KEY_FILE" ]]; then
        # Generate random key on first use
        head -c 32 /dev/urandom | base64 > "$ENCRYPTION_KEY_FILE"
        chmod 600 "$ENCRYPTION_KEY_FILE"
    fi
}

encrypt_value() {
    local plaintext="$1"
    [[ -z "$plaintext" ]] && return 0

    setup_encryption_key
    local key
    key=$(cat "$ENCRYPTION_KEY_FILE")

    echo -n "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -a -pass "pass:$key" 2>/dev/null
}

decrypt_value() {
    local ciphertext="$1"
    [[ -z "$ciphertext" ]] && return 0

    # Check if value is encrypted (starts with U2FsdGVk after base64 decode)
    if [[ ! "$ciphertext" =~ ^U2FsdGVk ]]; then
        # Not encrypted, return as-is (backward compatibility)
        echo "$ciphertext"
        return 0
    fi

    [[ ! -f "$ENCRYPTION_KEY_FILE" ]] && { echo "$ciphertext"; return 0; }

    local key
    key=$(cat "$ENCRYPTION_KEY_FILE")

    echo "$ciphertext" | openssl enc -aes-256-cbc -pbkdf2 -d -a -pass "pass:$key" 2>/dev/null || echo "$ciphertext"
}

# Check if config encryption is enabled
is_encryption_enabled() {
    [[ -f "$ENCRYPTION_KEY_FILE" ]] && [[ "${ENABLE_CONFIG_ENCRYPTION:-false}" == "true" ]]
}

# 配置目录（支持多节点）
NODES_DIR="/root/reality_nodes"
LANG_FILE="/root/reality_vision.lang"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_GEODATA_DIR="/usr/local/share/xray"
SERVICE="xray"

# sing-box（用于 AnyTLS / AnyTLS + REALITY / Hysteria2）
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_DIR="/usr/local/etc/sing-box"
SINGBOX_CONF="/usr/local/etc/sing-box/config.json"
SINGBOX_CERT_DIR="/usr/local/etc/sing-box/certs"
SINGBOX_SERVICE="sing-box"

# 缓存配置（放在 /root 下更安全）
CACHE_FILE="/root/.sni_latency_cache"
CACHE_TTL=3600  # 1小时

# 当前操作的节点名称
CURRENT_NODE_NAME=""

# 包管理器变量
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
PKG_CHECK=""

# 服务管理变量 (systemd 或 openrc)
INIT_SYSTEM=""

# WARP 配置
WARP_SOCKS_PORT=40000

PORT_MIN=10000
PORT_MAX=65535

# 语言设置 (zh/en)
CURRENT_LANG="${CURRENT_LANG:-}"

# Spinner 动画帧
SPINNER_FRAMES=('|' '/' '-' '\')

# SNI 域名列表（完整列表，用于延迟测试）
SNI_LIST=(
    "amd.com"
    "aws.com"
    "c.6sc.co"
    "j.6sc.co"
    "b.6sc.co"
    "intel.com"
    "r.bing.com"
    "th.bing.com"
    "www.amd.com"
    "www.aws.com"
    "ipv6.6sc.co"
    "www.xbox.com"
    "www.sony.com"
    "rum.hlx.page"
    "www.bing.com"
    "xp.apple.com"
    "www.wowt.com"
    "www.apple.com"
    "www.intel.com"
    "www.tesla.com"
    "www.xilinx.com"
    "www.oracle.com"
    "www.icloud.com"
    "apps.apple.com"
    "c.marsflag.com"
    "www.nvidia.com"
    "snap.licdn.com"
    "aws.amazon.com"
    "drivers.amd.com"
    "cdn.bizibly.com"
    "s.go-mpulse.net"
    "tags.tiqcdn.com"
    "cdn.bizible.com"
    "ocsp2.apple.com"
    "cdn.userway.org"
    "download.amd.com"
    "d1.awsstatic.com"
    "s0.awsstatic.com"
    "mscom.demdex.net"
    "a0.awsstatic.com"
    "go.microsoft.com"
    "apps.mzstatic.com"
    "sisu.xboxlive.com"
    "www.microsoft.com"
    "s.mp.marsflag.com"
    "images.nvidia.com"
    "vs.aws.amazon.com"
    "c.s-microsoft.com"
    "statici.icloud.com"
    "beacon.gtv-pub.com"
    "ts4.tc.mm.bing.net"
    "ts3.tc.mm.bing.net"
    "d2c.aws.amazon.com"
    "ts1.tc.mm.bing.net"
    "ce.mf.marsflag.com"
    "d0.m.awsstatic.com"
    "t0.m.awsstatic.com"
    "ts2.tc.mm.bing.net"
    "tag.demandbase.com"
    "assets-www.xbox.com"
    "logx.optimizely.com"
    "azure.microsoft.com"
    "aadcdn.msftauth.net"
    "d.oracleinfinity.io"
    "assets.adobedtm.com"
    "lpcdn.lpsnmedia.net"
    "res-1.cdn.office.net"
    "is1-ssl.mzstatic.com"
    "electronics.sony.com"
    "intelcorp.scene7.com"
    "acctcdn.msftauth.net"
    "cdnssl.clicktale.net"
    "catalog.gamepass.com"
    "consent.trustarc.com"
    "gsp-ssl.ls.apple.com"
    "munchkin.marketo.net"
    "s.company-target.com"
    "cdn77.api.userway.org"
    "cua-chat-ui.tesla.com"
    "assets-xbxweb.xbox.com"
    "ds-aksb-a.akamaihd.net"
    "static.cloud.coveo.com"
    "api.company-target.com"
    "devblogs.microsoft.com"
    "s7mbrstream.scene7.com"
    "fpinit.itunes.apple.com"
    "digitalassets.tesla.com"
    "d.impactradius-event.com"
    "downloadmirror.intel.com"
    "iosapps.itunes.apple.com"
    "se-edge.itunes.apple.com"
    "publisher.liveperson.net"
    "tag-logger.demandbase.com"
    "services.digitaleast.mobi"
    "configuration.ls.apple.com"
    "gray-wowt-prod.gtv-cdn.com"
    "visualstudio.microsoft.com"
    "prod.log.shortbread.aws.dev"
    "amp-api-edge.apps.apple.com"
    "store-images.s-microsoft.com"
    "cdn-dynmedia-1.microsoft.com"
    "github.gallerycdn.vsassets.io"
    "prod.pa.cdn.uis.awsstatic.com"
    "a.b.cdn.console.awsstatic.com"
    "d3agakyjgjv5i8.cloudfront.net"
    "vscjava.gallerycdn.vsassets.io"
    "location-services-prd.tesla.com"
    "ms-vscode.gallerycdn.vsassets.io"
    "ms-python.gallerycdn.vsassets.io"
    "gray-config-prod.api.arc-cdn.net"
    "i7158c100-ds-aksb-a.akamaihd.net"
    "downloaddispatch.itunes.apple.com"
    "res.public.onecdn.static.microsoft"
    "gray.video-player.arcpublishing.com"
    "gray-config-prod.api.cdn.arcpublishing.com"
    "img-prod-cms-rt-microsoft-com.akamaized.net"
    "prod.us-east-1.ui.gcr-chat.marketing.aws.dev"
)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

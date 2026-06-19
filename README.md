# Proxy Hub

一键部署多协议代理节点的自动化脚本，支持 VLESS Reality、Shadowsocks 2022、多节点管理、WARP 分流、系统优化工具和多语言界面。

## 特性

### 支持协议
- **VLESS + Vision + REALITY** - TCP 传输，推荐
- **VLESS + XHTTP + REALITY** - XHTTP 传输，更好的伪装
- **Shadowsocks 2022** - 高性能 SS 协议，支持多种加密方式
- **AnyTLS** - 基于 sing-box 的抗 "TLS in TLS" 检测协议，自签名证书
- **AnyTLS + REALITY** - AnyTLS 叠加 REALITY 伪装，抗封锁能力更强（推荐）

> AnyTLS 由 sing-box 提供（Xray 暂不支持 AnyTLS），脚本会在添加 AnyTLS 节点时
> 自动安装并管理 sing-box，与 Xray 各自独立运行、互不影响。每个 AnyTLS 节点都会
> 生成**独立、随机化的 padding scheme**，服务端在握手时自动下发给客户端，无需客户端额外配置。

### 核心功能
- **多节点支持** - 同时运行多个节点，独立配置
- **双栈链接** - 自动检测并生成 IPv4/IPv6 分享链接
- **动态 SNI** - 自动测试 117 个域名，选择最低延迟 SNI
- **并行测试** - 30 并发测试，5-10 秒完成（原需 4+ 分钟）
- **二维码** - 自动生成分享二维码

### 系统优化工具
- **WARP 分流** - Netflix/AI 服务智能分流
- **BBR 优化** - TCP 拥塞控制优化
- **Swap 管理** - 虚拟内存管理
- **Fail2ban** - SSH 暴力破解防护
- **端口管理** - SSH/Vision/XHTTP/SS 端口修改
- **日志查看** - 统一日志查看器

### 多系统支持
- **Linux 发行版** - Debian/Ubuntu/CentOS/RHEL/Fedora/Alpine
- **Init 系统** - systemd 和 OpenRC
- **包管理器** - apt/dnf/yum/apk

### 安全特性
- **单实例锁** - 防止脚本重复运行
- **安全配置加载** - 防止配置文件注入攻击
- **IPv6 SSH 保护** - 防止禁用 IPv6 时断开连接
- **包管理器检查** - 等待系统更新完成后再安装

## 快速开始

### 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh)
```

### 手动安装

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/Banezzz/proxy-hub/main/proxy-hub.sh

# 添加执行权限
chmod +x proxy-hub.sh

# 运行
./proxy-hub.sh
```

## 使用方法

### 交互式菜单

```bash
./proxy-hub.sh
```

```
╔═══════════════════════════════════════════════════════════════╗
║              Proxy Hub 管理面板                               ║
╠═══════════════════════════════════════════════════════════════╣
║   1. 安装节点 (Add Node)                                       ║
║   2. 查看节点信息                                              ║
║   3. 显示二维码                                                ║
║   4. 服务状态 [●] (3 nodes)                                    ║
║   5. List Nodes / 列出节点                                     ║
║   6. Remove Node / 删除节点                                    ║
║   7. 重启服务                                                  ║
║   8. 测试 SNI 延迟                                             ║
║   9. 健康检查                                                  ║
╠═══════════════════════════════════════════════════════════════╣
║   T. 系统工具 (WARP/BBR/Swap/Fail2ban/Ports/Logs)              ║
╠═══════════════════════════════════════════════════════════════╣
║   L. 切换语言                                                  ║
║   U. 卸载 (All)                                                ║
║   0. 退出                                                      ║
╚═══════════════════════════════════════════════════════════════╝
```

### 协议选择

安装节点时可以选择：

```
═══════════════════════════════════════════════════════════════
                     选择节点协议类型
═══════════════════════════════════════════════════════════════

  1. VLESS + Vision + REALITY  (TCP 传输, 推荐)
  2. VLESS + XHTTP + REALITY   (XHTTP 传输)
  3. 两个都安装               (生成两个端口)
  4. Shadowsocks 2022         (SS 协议, 高性能)
  5. AnyTLS                   (sing-box, 自签名证书)
  6. AnyTLS + REALITY         (sing-box, 抗封锁, 推荐)
```

### Shadowsocks 加密方式

选择 Shadowsocks 时支持以下加密方式：

| 方式 | 说明 |
|------|------|
| `2022-blake3-aes-256-gcm` | 推荐，硬件加速 |
| `2022-blake3-chacha20-poly1305` | 移动设备优化 |
| `chacha20-ietf-poly1305` | 传统方式，广泛支持 |
| `aes-256-gcm` | 传统方式，经典加密 |

### 命令行模式

```bash
# 节点管理
./proxy-hub.sh install     # 添加新节点
./proxy-hub.sh list        # 列出所有节点
./proxy-hub.sh info        # 查看节点信息
./proxy-hub.sh qr          # 显示二维码
./proxy-hub.sh status      # 服务状态
./proxy-hub.sh health      # 健康检查
./proxy-hub.sh remove      # 删除节点
./proxy-hub.sh restart     # 重启服务
./proxy-hub.sh test-sni    # 测试 SNI 延迟
./proxy-hub.sh uninstall   # 卸载所有节点和 Xray

# 系统工具
./proxy-hub.sh tools       # 系统工具菜单
./proxy-hub.sh ports       # 端口管理
./proxy-hub.sh logs        # 日志查看
./proxy-hub.sh warp        # WARP 分流管理
./proxy-hub.sh bbr         # BBR 优化
./proxy-hub.sh swap        # Swap 管理
./proxy-hub.sh fail2ban    # Fail2ban 管理
```

### 高级参数

```bash
# VLESS Vision 节点
name=hk1 proto=vision vlpt=443 reym=www.microsoft.com ./proxy-hub.sh install

# VLESS XHTTP 节点
name=jp1 proto=xhttp xhpt=8443 reym=www.apple.com ./proxy-hub.sh install

# VLESS Vision + XHTTP 双协议
name=sg1 proto=both vlpt=443 xhpt=8443 ./proxy-hub.sh install

# Shadowsocks 2022 节点
name=us1 proto=shadowsocks sspt=8388 ./proxy-hub.sh install

# AnyTLS 节点 (自签名证书)
name=at1 proto=anytls atpt=8443 ./proxy-hub.sh install

# AnyTLS + REALITY 节点 (推荐)
name=ar1 proto=anytls-reality atpt=443 reym=www.microsoft.com ./proxy-hub.sh install

# 指定 UUID (VLESS)
uuid=your-custom-uuid ./proxy-hub.sh install

# 组合使用
name=de1 proto=vision vlpt=12345 reym=www.tesla.com ./proxy-hub.sh install
```

### 参数说明

| 参数 | 说明 | 示例 |
|------|------|------|
| `name` | 节点名称 | `name=hk1` |
| `proto` | 协议类型 | `proto=vision/xhttp/both/shadowsocks/anytls/anytls-reality` |
| `vlpt` | Vision 端口 | `vlpt=443` |
| `xhpt` | XHTTP 端口 | `xhpt=8443` |
| `sspt` | Shadowsocks 端口 | `sspt=8388` |
| `atpt` | AnyTLS 端口 | `atpt=8443` |
| `atpwd` | AnyTLS 密码 (默认随机) | `atpwd=xxxxxxxx` |
| `reym` | SNI 域名 (VLESS / AnyTLS+REALITY) | `reym=www.microsoft.com` |
| `uuid` | 自定义 UUID | `uuid=xxx-xxx-xxx` |

## 系统工具

### WARP 分流

通过 WARP Socks5 代理实现智能分流：

```bash
./proxy-hub.sh warp
```

功能：
- 安装/卸载 WARP
- Netflix 分流 (解锁地区限制)
- AI 服务分流 (OpenAI/Claude/Gemini)
- 自定义分流规则

### BBR 优化

TCP 拥塞控制优化：

```bash
./proxy-hub.sh bbr
```

功能：
- 启用/禁用 BBR
- TCP 参数优化
- 网络缓冲区调优

### 端口管理

```bash
./proxy-hub.sh ports
```

```
═══════════════════════════════════════════════════════════════
              端口管理面板 (Port Manager)
═══════════════════════════════════════════════════════════════

  服务              端口            状态
───────────────────────────────────────────────────────────────
  1. 修改 SSH          22            运行中
  2. 修改 Vision       12345         运行中
  3. 修改 XHTTP        8443          运行中
  4. 修改 Shadowsocks  8388          运行中
───────────────────────────────────────────────────────────────
  0. 返回 (Back)
```

**注意**: 修改 SSH 端口前，请确保已在云服务商控制台放行新端口！

### 日志查看

```bash
./proxy-hub.sh logs
```

支持查看：
- Xray 运行日志
- Xray 错误日志
- SSH 登录日志
- Fail2ban 日志
- 系统日志

### 独立工具命令

安装独立工具后，可直接使用以下命令：

```bash
xray-info    # 查看节点信息
xray-ports   # 端口管理
xray-logs    # 日志查看
xray-bbr     # BBR 管理
xray-swap    # Swap 管理
xray-warp    # WARP 管理
xray-f2b     # Fail2ban 管理
```

在系统工具菜单中选择"安装独立工具命令"即可安装。

## 多节点管理

### 添加节点

```bash
# 交互式添加（会提示选择协议类型和端口）
./proxy-hub.sh install

# 命令行添加 VLESS 节点
name=hk1 proto=vision ./proxy-hub.sh install
name=jp1 proto=xhttp ./proxy-hub.sh install

# 命令行添加 Shadowsocks 节点
name=ss1 proto=shadowsocks sspt=8388 ./proxy-hub.sh install
```

### 查看所有节点

```bash
./proxy-hub.sh list
```

输出示例：
```
═══════════════════════════════════════════════════════════════
                     All Nodes / 所有节点
═══════════════════════════════════════════════════════════════

  1. hk1 [VLESS Vision]
     Port: 12345 | SNI: www.microsoft.com
     UUID: 03761544...
     XHTTP: 8443

  2. ss1 [Shadowsocks]
     Port: 8388 | Method: 2022-blake3-aes-256-gcm
     Password: abc123...

═══════════════════════════════════════════════════════════════
```

## 系统要求

- **操作系统**: Debian 10+, Ubuntu 18.04+, CentOS 7+, RHEL 7+, Fedora 30+, Alpine 3.14+
- **Init 系统**: systemd 或 OpenRC
- **Bash**: 4.3+（脚本会自动检测）
- **架构**: x86_64, aarch64
- **权限**: root 用户
- **网络**: 需要访问 GitHub 下载 Xray

## 客户端配置

### VLESS Vision 协议

```
协议: VLESS
地址: your.server.ip
端口: 12345
UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Flow: xtls-rprx-vision
传输: TCP
安全: Reality
SNI: www.microsoft.com
Fingerprint: chrome
PublicKey: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ShortID: xxxxxxxx
```

### VLESS XHTTP 协议

```
协议: VLESS
地址: your.server.ip
端口: 8443
UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
传输: XHTTP
安全: Reality
SNI: www.microsoft.com
Fingerprint: chrome
PublicKey: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ShortID: xxxxxxxx
```

### Shadowsocks 2022

```
协议: Shadowsocks
地址: your.server.ip
端口: 8388
加密: 2022-blake3-aes-256-gcm
密码: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### AnyTLS

```
协议: AnyTLS
地址: your.server.ip
端口: 8443
密码: xxxxxxxxxxxxxxxx
SNI: www.bing.com
允许不安全 (insecure): 是   # 自签名证书
```

分享链接格式：`anytls://密码@地址:端口/?sni=域名&insecure=1#名称`

### AnyTLS + REALITY

```
协议: AnyTLS
地址: your.server.ip
端口: 443
密码: xxxxxxxxxxxxxxxx
SNI: www.microsoft.com
PublicKey: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ShortID: xxxxxxxx
Fingerprint: chrome
```

分享链接格式：`anytls://密码@地址:端口/?sni=域名&pbk=公钥&sid=ShortID&fp=chrome#名称`

> AnyTLS 需要支持该协议的客户端：[sing-box](https://github.com/SagerNet/sing-box)、
> [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo)、NekoBox 等。
> 旧版 v2rayN/v2rayNG（仅 Xray 内核）不支持 AnyTLS。

### 推荐客户端

| 平台 | 客户端 |
|------|--------|
| Windows | [v2rayN](https://github.com/2dust/v2rayN) |
| macOS | [V2rayU](https://github.com/yanue/V2rayU) |
| iOS | Shadowrocket, Quantumult X |
| Android | [v2rayNG](https://github.com/2dust/v2rayNG) |
| Linux | [v2rayA](https://github.com/v2rayA/v2rayA) |

## 文件位置

| 文件 | 路径 |
|------|------|
| Xray 程序 | `/usr/local/bin/xray` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| GeoIP 数据 | `/usr/local/share/xray/geoip.dat` |
| GeoSite 数据 | `/usr/local/share/xray/geosite.dat` |
| 节点配置目录 | `/root/reality_nodes/` |
| 单节点配置 | `/root/reality_nodes/<name>.env` |
| 语言设置 | `/root/reality_vision.lang` |
| SNI 缓存 | `/root/.sni_latency_cache` |
| 独立工具 | `/usr/local/bin/xray-*` |

## 常见问题

### Q: 安装后无法连接？

1. 运行 `./proxy-hub.sh status` 检查服务状态
2. 确保服务器防火墙/安全组开放了对应端口
3. 检查客户端配置是否正确
4. 查看日志：`./proxy-hub.sh logs`

### Q: SNI 测试全部超时？

- 可能是服务器网络限制，使用 `reym=www.tesla.com` 指定 SNI 跳过测试

### Q: 如何更换某个节点的 SNI？

```bash
# 删除旧节点，重新添加
./proxy-hub.sh remove
name=hk1 reym=new.sni.com ./proxy-hub.sh install
```

### Q: 如何修改端口？

```bash
./proxy-hub.sh ports
# 选择要修改的端口类型
```

### Q: WARP 分流不生效？

1. 确认 WARP 服务运行中：`./proxy-hub.sh warp`
2. 检查 Xray 配置中是否有 WARP outbound
3. 重启 Xray 服务：`./proxy-hub.sh restart`

### Q: Shadowsocks 密码错误？

确保客户端使用完整的 base64 密码，包括末尾的 `==` 填充字符。

### Q: Alpine Linux 支持如何？

完全支持 Alpine Linux，使用 OpenRC 作为 init 系统，apk 作为包管理器。

### Q: 多节点共用一个 Xray 进程吗？

是的，所有节点配置在同一个 Xray 配置文件中作为多个 inbounds，共用一个 Xray 进程。

## 更新日志

### v5.4.0
- SNI 选择时新增「测试自定义域名」(`C`)：可输入逗号分隔的多个域名
  （如 `a.com,b.com,c.com`），仅对这些域名测速，并从结果中选择 SNI
- 内置 117 域名测速结果之外的补充手段，安装与编辑节点时均可用

### v5.3.0
- 新增「编辑节点」功能（菜单 `E` / 命令 `edit`）：节点创建后可修改参数
  - VLESS：端口、SNI/dest（测速或自定义）、重新生成 UUID / Reality 密钥对、XHTTP path
  - Shadowsocks：端口、加密方式、重新生成密码
  - AnyTLS / AnyTLS+REALITY：端口、SNI、重新生成密码 / padding / Reality 密钥对
- 单独 AnyTLS（自签证书）现已支持自定义 SNI：创建与编辑均可「测速选择 + 手动输入」

### v5.2.0
- 按需安装代理内核：在选择协议类型之后才安装对应内核
  （VLESS/Shadowsocks → Xray，AnyTLS → sing-box），不再默认安装 Xray
- AnyTLS + REALITY 的密钥改用 sing-box 生成，AnyTLS 节点完全无需 Xray
- 不再默认下载 GeoIP/GeoSite 数据库；默认路由用显式私网 CIDR 替代
  `geoip:private`（保留拦截内网/环回的安全策略），仅在启用 WARP 分流时
  才按需下载 GeoSite 数据库

### v5.1.1
- 修复「更新节点 IP」只按首个节点判断是否变更，导致换 IP 前已存在的旧节点
  不被同步（分享链接仍显示旧 IP）的问题，改为逐节点独立比较与更新

### v5.1.0
- 新增 **AnyTLS** 与 **AnyTLS + REALITY** 协议支持（基于 sing-box）
- 每个 AnyTLS 节点生成独立、随机化的 padding scheme，握手时自动下发给客户端
- sing-box 按需自动安装/卸载，与 Xray 独立运行（systemd / OpenRC 双支持）
- 节点列表、状态、健康检查、二维码、分享链接均已适配 AnyTLS

### v5.0.0
- 项目重命名为 Proxy Hub
- 新增 Shadowsocks 2022 协议支持
- 支持多种 SS 加密方式 (2022-blake3-aes-256-gcm, chacha20-ietf-poly1305 等)
- 交互式端口选择
- 安全增强：配置文件安全加载，防止注入攻击
- 修复 base64 密码解析问题

### v4.0.0
- XHTTP 协议支持
- IPv4/IPv6 双栈链接生成
- GeoIP/GeoSite 规则数据库
- WARP 分流功能
- BBR/Swap 系统优化工具
- Fail2ban SSH 防护
- 端口管理功能
- 日志查看器
- 独立工具命令安装
- Alpine Linux / OpenRC 支持
- 单实例锁机制
- IPv6 SSH 自杀保护
- 包管理器状态检查

### v3.0.0
- 多节点支持（同时运行多个独立节点）
- 交互式节点命名（直接回车使用随机名称）
- 节点管理命令（list/remove）
- 智能 xray 配置合并
- 每个节点独立连接数统计

### v2.0.0
- 并行 SNI 测试（30 并发，性能提升 28-56 倍）
- 并行 IP 获取（4 API 竞速）
- 多发行版支持（apt/yum/dnf）
- 健康检查功能
- 连接数显示
- SNI 测试结果缓存

### v1.0.0
- 初始版本
- VLESS + TCP + REALITY 自动配置
- 动态 SNI 选择
- 多语言支持
- 二维码生成

## 致谢

- [Xray-core](https://github.com/XTLS/Xray-core) - 核心代理引擎
- [REALITY](https://github.com/XTLS/REALITY) - 协议实现
- [Loyalsoldier](https://github.com/Loyalsoldier/v2ray-rules-dat) - GeoIP/GeoSite 规则
- [WARP](https://github.com/fscarmen/warp) - WARP 实现参考

## License

MIT License

# VLESS TCP REALITY Vision Auto-Setup

一键部署 VLESS + TCP + REALITY Vision 节点的自动化脚本，支持多节点、XHTTP 协议、WARP 分流、系统优化工具和多语言界面。

## 特性

### 核心功能
- **多节点支持** - 同时运行多个节点，独立配置
- **XHTTP 协议** - 可选启用 XHTTP 协议，提供更好的伪装
- **双栈链接** - 自动检测并生成 IPv4/IPv6 分享链接
- **动态 SNI** - 自动测试 117 个域名，选择最低延迟 SNI
- **并行测试** - 30 并发测试，5-10 秒完成（原需 4+ 分钟）
- **二维码** - 自动生成分享二维码

### 系统优化工具
- **WARP 分流** - Netflix/AI 服务智能分流
- **BBR 优化** - TCP 拥塞控制优化
- **Swap 管理** - 虚拟内存管理
- **Fail2ban** - SSH 暴力破解防护
- **端口管理** - SSH/Vision/XHTTP 端口修改
- **日志查看** - 统一日志查看器

### 多系统支持
- **Linux 发行版** - Debian/Ubuntu/CentOS/RHEL/Fedora/Alpine
- **Init 系统** - systemd 和 OpenRC
- **包管理器** - apt/dnf/yum/apk

### 安全特性
- **单实例锁** - 防止脚本重复运行
- **IPv6 SSH 保护** - 防止禁用 IPv6 时断开连接
- **包管理器检查** - 等待系统更新完成后再安装

## 快速开始

### 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Banezzz/reality-vision---fast-setup/main/vless-reality-vision.sh)
```

### 手动安装

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/Banezzz/reality-vision---fast-setup/main/vless-reality-vision.sh

# 添加执行权限
chmod +x vless-reality-vision.sh

# 运行
./vless-reality-vision.sh
```

## 使用方法

### 交互式菜单

```bash
bash vless-reality-vision.sh
```

```
╔═══════════════════════════════════════════════════════════════╗
║         VLESS TCP REALITY Vision 管理面板                      ║
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

### 命令行模式

```bash
# 节点管理
bash vless-reality-vision.sh install     # 添加新节点
bash vless-reality-vision.sh list        # 列出所有节点
bash vless-reality-vision.sh info        # 查看节点信息
bash vless-reality-vision.sh qr          # 显示二维码
bash vless-reality-vision.sh status      # 服务状态
bash vless-reality-vision.sh health      # 健康检查
bash vless-reality-vision.sh remove      # 删除节点
bash vless-reality-vision.sh restart     # 重启服务
bash vless-reality-vision.sh test-sni    # 测试 SNI 延迟
bash vless-reality-vision.sh uninstall   # 卸载所有节点和 Xray

# 系统工具
bash vless-reality-vision.sh tools       # 系统工具菜单
bash vless-reality-vision.sh ports       # 端口管理
bash vless-reality-vision.sh logs        # 日志查看
bash vless-reality-vision.sh warp        # WARP 分流管理
bash vless-reality-vision.sh bbr         # BBR 优化
bash vless-reality-vision.sh swap        # Swap 管理
bash vless-reality-vision.sh fail2ban    # Fail2ban 管理
```

### 高级参数

```bash
# 指定节点名称
name=hk1 bash vless-reality-vision.sh install

# 指定 SNI 域名
reym=www.microsoft.com bash vless-reality-vision.sh install

# 指定端口
vlpt=443 bash vless-reality-vision.sh install

# 指定 UUID
uuid=your-custom-uuid bash vless-reality-vision.sh install

# 启用 XHTTP 协议
xhttp=true bash vless-reality-vision.sh install

# 指定 XHTTP 端口
xhttp=true xhpt=8443 bash vless-reality-vision.sh install

# 组合使用
name=jp1 reym=www.apple.com vlpt=8443 xhttp=true bash vless-reality-vision.sh install
```

## 系统工具

### WARP 分流

通过 WARP Socks5 代理实现智能分流：

```bash
bash vless-reality-vision.sh warp
```

功能：
- 安装/卸载 WARP
- Netflix 分流 (解锁地区限制)
- AI 服务分流 (OpenAI/Claude/Gemini)
- 自定义分流规则

### BBR 优化

TCP 拥塞控制优化：

```bash
bash vless-reality-vision.sh bbr
```

功能：
- 启用/禁用 BBR
- TCP 参数优化
- 网络缓冲区调优

### 端口管理

```bash
bash vless-reality-vision.sh ports
```

```
═══════════════════════════════════════════════════════
              端口管理面板 (Port Manager)
═══════════════════════════════════════════════════════

  服务              端口            状态
───────────────────────────────────────────────────────
  1. 修改 SSH          22            运行中
  2. 修改 Vision       12345         运行中
  3. 修改 XHTTP        8443          运行中
───────────────────────────────────────────────────────
  0. 返回 (Back)
```

**注意**: 修改 SSH 端口前，请确保已在云服务商控制台放行新端口！

### 日志查看

```bash
bash vless-reality-vision.sh logs
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
# 交互式添加（会提示输入名称，直接回车使用随机名称）
bash vless-reality-vision.sh install

# 命令行指定名称
name=hk1 bash vless-reality-vision.sh install
name=jp1 bash vless-reality-vision.sh install
name=sg1 bash vless-reality-vision.sh install

# 添加带 XHTTP 的节点
name=us1 xhttp=true bash vless-reality-vision.sh install
```

### 查看所有节点

```bash
bash vless-reality-vision.sh list
```

输出示例：
```
═══════════════════════════════════════════════════════════════
                     All Nodes / 所有节点
═══════════════════════════════════════════════════════════════

  1. hk1
     Port: 12345 | SNI: www.microsoft.com
     UUID: 03761544...
     XHTTP: 8443

  2. jp1
     Port: 23456 | SNI: www.apple.com
     UUID: a1b2c3d4...

═══════════════════════════════════════════════════════════════
```

### 节点信息

安装完成后会显示双栈链接：

```
═══════════════════════════════════════════════════════════════
                    节点信息 / Node Info
═══════════════════════════════════════════════════════════════

Node Name:  hk1
服务器地址:
  IPv4: 1.2.3.4
  IPv6: 2001:db8::1
Vision 端口: 12345
XHTTP 端口:  8443

═══════════════════════════════════════════════════════════════
                    IPv4 Links
───────────────────────────────────────────────────────────────
Vision: vless://uuid@1.2.3.4:12345?...
XHTTP:  vless://uuid@1.2.3.4:8443?...

═══════════════════════════════════════════════════════════════
                    IPv6 Links
───────────────────────────────────────────────────────────────
Vision: vless://uuid@[2001:db8::1]:12345?...
XHTTP:  vless://uuid@[2001:db8::1]:8443?...
```

## 系统要求

- **操作系统**: Debian 10+, Ubuntu 18.04+, CentOS 7+, RHEL 7+, Fedora 30+, Alpine 3.14+
- **Init 系统**: systemd 或 OpenRC
- **Bash**: 4.3+（脚本会自动检测）
- **架构**: x86_64, aarch64
- **权限**: root 用户
- **网络**: 需要访问 GitHub 下载 Xray

## 客户端配置

### Vision 协议

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

### XHTTP 协议

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

1. 运行 `bash vless-reality-vision.sh status` 检查服务状态
2. 确保服务器防火墙/安全组开放了对应端口
3. 检查客户端配置是否正确
4. 查看日志：`bash vless-reality-vision.sh logs`

### Q: SNI 测试全部超时？

- 可能是服务器网络限制，使用 `reym=www.tesla.com` 指定 SNI 跳过测试

### Q: 如何更换某个节点的 SNI？

```bash
# 删除旧节点，重新添加
bash vless-reality-vision.sh remove
name=hk1 reym=new.sni.com bash vless-reality-vision.sh install
```

### Q: 如何修改端口？

```bash
bash vless-reality-vision.sh ports
# 选择要修改的端口类型
```

### Q: WARP 分流不生效？

1. 确认 WARP 服务运行中：`bash vless-reality-vision.sh warp`
2. 检查 Xray 配置中是否有 WARP outbound
3. 重启 Xray 服务：`bash vless-reality-vision.sh restart`

### Q: Alpine Linux 支持如何？

完全支持 Alpine Linux，使用 OpenRC 作为 init 系统，apk 作为包管理器。

### Q: 多节点共用一个 Xray 进程吗？

是的，所有节点配置在同一个 Xray 配置文件中作为多个 inbounds，共用一个 Xray 进程。

## 更新日志

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

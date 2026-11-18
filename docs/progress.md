# 变更记录

## 2026-11-18 — 协议刷新的后续：加密缺陷、Xray 承载 Hysteria2、shortId 升级项

- **修复可选配置加密写出多行密文**。`ENABLE_CONFIG_ENCRYPTION=true` 时 `encrypt_value`
  的 base64 每 64 字符换行，UUID 与 REALITY 私钥的密文都是两行，写进逐行的节点文件
  后第二行丢失、节点无法再读出。密文现在恒为单行。同时修正失败语义：解不开的密文
  不再被原样当作明文返回（那会把 base64 写进内核配置），`load_node_for_edit` 遇到
  解不开的字段即中止，不会在重存时用空值覆盖仅存的密文。
- **Hysteria2 可由 Xray 承载**。`hy2core=xray`（安装）或节点编辑里的"切换承载内核"。
  默认仍是 sing-box；两个后端对客户端等价，分享链接不变。节点归属的判断收拢到
  `node_core_of` 一处。Xray 不支持的组合（ACME、OpenRC 上的端口跳跃、低于 v26.3.27）
  在写入任何东西之前被拒绝。端口跳跃的 NAT 规则同时挂到 xray 服务。
- **升级向导新增 `node.<name>.shortid`**（可选、会改链接、默认不勾选），说明里写明
  收益有限。
- `help` 补上上一轮新增却没有列出的 Hysteria2 / REALITY / VLESS 安装参数。

影响范围：`encrypt_value` / `decrypt_value` 与全部经它们读写的敏感字段、节点编辑与
升级向导的加载路径；Hysteria2 的安装、编辑、回滚、两个内核的配置渲染与节点计数、
端口跳跃 drop-in；升级扫描与执行；`help`。节点 env 新增可选字段 `HY2_CORE`。

兼容性：

- 未启用加密的安装不受加密修复影响。启用了加密且节点文件里已有被截断的密文的，
  数据在旧版本写入时就已丢失，无法恢复；现在的表现是该字段读作空并告警、节点编辑
  被拒绝，而不是把密文写进配置。这类节点需要重新生成凭据或重装。
- `HY2_CORE` 缺失即 sing-box，既有 Hysteria2 节点的归属、配置与链接都不变。
- `rollback_candidate_node` 增加可选的第三个参数（内核），省略时按协议的默认归属，
  既有调用方式不变。

验证方式：`bash tests/test_protocol_refresh.sh`（27 个场景）与
`bash tests/test_upgrade.sh`。新增的加密场景在修复前的代码上于第一条断言失败（36
字节的值加密成两行），修复后覆盖全部敏感字段经 `save_env`、加载器与渲染器的往返，
以及截断密文与密钥文件缺失。Hysteria2 的两个后端在提供真实内核时由
`hysteria2-interop` 场景做回环互通：真实 Xray 26.11.9 / sing-box 1.14.4 作服务端、
真实 sing-box 作客户端，每个后端 6 次探测（明文、错误密码、多余混淆、匹配的
Salamander、缺混淆、错误混淆密码）加 1 个无入站对照，共 13 次，全部符合预期。这同时
是 sing-box 后端 Salamander 选项的首次端到端证据。

未验证：Xray 承载的 Hysteria2 在 IPv6 上的行为（验证环境没有 IPv6），见
`docs/audits.md`。`tests/test_loader.sh` 与 `tests/test_xray_transaction.sh` 在该环境中
仍各有一个与本轮无关、改动前就存在的失败用例。

## 2026-11-18 — 协议刷新、引导菜单与升级向导

对照上游截至 2026-11 的状态（Xray v26.11.9、sing-box 1.14.4）更新协议层，并为旧版
脚本留下的节点与内核提供迁移路径。

- **升级向导**：`upgrade_scan` 离线扫描内核版本、Xray 配置字段、服务加固、cron、
  sysctl 与每个节点，产出按"对客户端的代价"分类的可升级项（safe / relink / info）。
  打开交互菜单时若有未看过的项会提示一次；向导逐项给出"为什么 / 代价"，推荐项默认
  勾选、回车即执行，会改链接的项需主动勾选并二次确认。执行顺序固定为内核 → 节点与
  配置 → 系统项，节点改动先快照、失败整体恢复。新增 `upgrade`、`upgrade check`、
  `upgrade apply recommended|all|ID`，主菜单新增 `P`。
- **引导菜单**：协议选择、Hysteria2 加固、后量子选项、BBR 菜单都加了逐项说明；复杂
  功能提供回车即用的推荐方案，密码、端口范围、密钥随机生成。脚本化安装不被提问。
- **REALITY**：按内核能力写 `target`（旧内核仍写 `dest`），去掉服务端无效的
  `fingerprint`；默认端口优先 443；shortId 加长为 16 位并支持附加 shortId；候选域名
  移除 Apple/iCloud 系（117 → 102），测速要求 TLS 1.3 并按 ASN/CDN 重排。
- **VLESS**：`both` 节点的 XHTTP 使用独立 UUID/密钥/shortId；可选 VLESS Encryption
  （启用后 XHTTP 也使用 Vision 流控）与 REALITY ML-DSA-65；XHTTP 链接带 `mode=auto`。
- **Hysteria2**：分享链接加入 `pinSHA256`；可选 Salamander 混淆、端口跳跃（专用 NAT
  链 + 随服务启动重下发）与 ACME 证书（按 sing-box 版本选择 provider 或内联写法）。
- **sing-box**：安装与更新强制校验 release 元数据里的 SHA-256，候选 binary 须可执行、
  版本匹配并通过现有配置检查，rename 原子替换，启动失败回滚。新增
  `singbox-version`、`singbox-update`。
- **加固**：服务沙箱 drop-in（健康门之后下发，起不来自动撤销）；GeoData 对照
  `.sha256sum` 校验后原子替换，cron 改走同一 helper；WARP 第三方脚本执行前显示摘要
  并可固定，移除"执行当前目录 menu.sh"的回退；健康检查提示低于安全基线的内核；
  sysctl 模板去掉失效的 `tcp_low_latency`。
- **Shadowsocks 2022** 在菜单与文档中重新定位为中转/落地用途，功能不变。

影响范围：协议选择与安装流程、节点 env schema（新增字段全部可选）、Xray/sing-box
配置渲染、分享链接与二维码、sing-box 安装路径、GeoData 与 WARP 的下载路径、systemd
drop-in、sysctl 调优文件、健康检查输出、主菜单与工具菜单、`help`、卸载清理。

兼容性：

- 既有节点文件无需迁移。缺少新字段的节点在**同一个内核**上渲染结果不变；内核支持
  `target` 时，重建配置会把 `dest` 换成 `target` 并去掉 `fingerprint`，这两处对客户端
  没有影响。
- 既有分享链接继续有效，例外只有用户在向导里主动勾选的 relink 项。Hysteria2 的新
  链接多了 `pinSHA256`，XHTTP 的新链接多了 `mode=auto`，旧链接不受影响。
- 用 `proto=` 等变量驱动的无人值守安装不出现新提问，增强项默认关闭。**完全交互**地
  安装 Hysteria2 时默认选择变为"Salamander 混淆"，这是有意的行为变化。
- 新装的 REALITY 节点默认端口变为 443（空闲时）、shortId 变为 16 位；显式指定的
  端口不受影响。
- sing-box 的安装从"下载即用"变为"摘要缺失即拒绝"，见 `docs/audits.md` 中关于该
  字段未对真实 API 验证的条目。

验证方式：`bash tests/test_protocol_refresh.sh`（23 个场景）与
`bash tests/test_upgrade.sh`（4 个场景）；前者在设置 `PROXY_HUB_TEST_XRAY_BIN` /
`PROXY_HUB_TEST_SINGBOX_BIN` 时用真实的 Xray 26.11.9 与 sing-box 1.14.4 校验渲染出的
配置（REALITY target、多 shortId、拆分凭据、ML-DSA-65、两种认证的 VLESS
Encryption、Salamander、ACME provider）。加固指令集经 systemd 255 的
`systemd-analyze verify`。另在 PTY 下跑过真实的零参数菜单、`help`、`upgrade check`
与 bundle 的 `singbox-version`。随后运行 `bash scripts/build-bundle.sh`、全量语法检查、
仓库完整测试与 `git diff --check`。

未验证的部分记录在 `docs/audits.md`：真实 GitHub API 的摘要字段、ACME 实际签发、
加固下的真实服务启动、客户端对 `mport` 的支持。实现本轮改动的环境中
`tests/test_loader.sh` 与 `tests/test_xray_transaction.sh` 在改动前后都各有一个用例
失败（失败点相同，分别是 `sourced loader caller-state preservation` 与
`late stage arrival is classified as conflict`），其后的用例因此没有执行。

## 2026-07-28 — 网络栈（IPv4 / IPv6）选择

- 新增实例级网络栈设置（`/root/.proxy_hub_netstack`，取值 `dual`/`v4`/`v6`，默认
  `dual`），主菜单 `N`、`netstack`/`ipstack` 命令和 `ipstack=` 环境变量三条入口共用
  同一套规范化、校验与应用逻辑；`netstack` 属于写操作，沿用单实例写锁。
- 三档语义：`dual` 保持通配监听与 Xray 默认 `AsIs` 出站；`v4` 收敛为
  `domainStrategy=UseIPv4`、只测 IPv4 可达 SNI、只探测并输出 IPv4；`v6` 额外写
  `streamSettings.sockopt.v6only`（Xray 转成 `IPV6_V6ONLY`）、`UseIPv6`、只测 IPv6
  可达 SNI、只输出 IPv6。
- `dual` 档产物与本次改动前逐字段一致：通配监听在 Linux 上本就是双栈 socket，
  Xray 文档亦说明 `"0.0.0.0"` 与 `"::"` 等价，因此默认档刻意不改写监听地址——以
  `ipv6.disable=1` 启动的内核上绑定 `"::"` 会让服务无法启动。两个内核在该档也各自
  保留历史写法（Xray `"0.0.0.0"`、sing-box `"::"`）。
- 出站只使用 `UseIPv4`/`UseIPv6` 这类长期存在的枚举值，避免较新的 `UseIPv4v6` 让
  未升级的既有 Xray binary 在 `xray -test` 阶段拒绝配置，把装节点变成安装失败。
- SNI 测速与自定义 SNI 连通性检查按档位附加 `openssl s_client -4/-6`：REALITY 的
  dest 握手由服务器自己发起，v6 Only 主机上只有 A 记录的域名会被测成"可用"，
  从而装出握手必然失败的节点。
- 设置文件按不可信输入处理（缺失/空/符号链接/非法内容一律回退 `dual`，原始内容不
  进入配置也不被求值）；切换按"保存 → 重建两个内核配置 → 重启"执行，任一步失败
  都恢复原设置并再次重建，尚无节点时只保存。

影响范围：Xray/sing-box inbound 监听、Xray freedom 出站、SNI 测速、服务器 IP 探测、
`update-ip`、分享链接与二维码的协议族范围，以及主菜单、`help` 和卸载清理。节点
`.env` schema、UUID、REALITY 密钥、端口与密码均不变。

兼容性：默认 `dual` 与升级前行为一致，既有节点无需重装。切到 `v6` 后查看只记录了
IPv4 的旧节点仍会回退输出单条链接，不会出现"一条链接都没有"。`v4` 档不做 socket
级强制（边界见 `docs/audits.md`）；sing-box 无 `v6only` 等价字段，`v6` 档下
AnyTLS / Hysteria2 仍为双栈绑定。

验证方式：`bash tests/test_netstack.sh` 覆盖三档的监听地址、sockopt 有无与
streamSettings 合并完整性、出站 `domainStrategy`、sing-box 监听、SNI 测速参数、
IP 探测与链接协议族、地址族不匹配旧节点的回退、非法设置回退与切换失败回滚；
另以真实 Xray binary 对三档产物执行 `xray -test -config`；随后运行
`bash scripts/build-bundle.sh`、`bash -n` 全量语法检查、仓库完整测试与
`git diff --check`。

## 2026-07-21 — Xray Release Management

- 新增 `xray-version` 与 `xray-update` CLI，并在中英文系统工具菜单和 `help` 中加入
  Xray Version / Update。版本 resolver 支持 stable、包括 prerelease 的最新非 draft
  release 与固定版本，优先级为 `XRAY_VERSION > XRAY_CHANNEL > stable`，同时兼容
  `xray_version`/`xray_channel` 小写别名。
- 普通节点安装检测到可运行且能报告版本的现有 Xray 时只显示并保留该版本，不再因
  stable 默认值覆盖、升级或降级；全新安装和显式更新复用同一 release 下载/验证路径。
- Xray release zip 必须通过同一官方 release 的 SHA-256 digest；随后继续验证 zip、
  新 binary 可执行且版本匹配，并以新 binary 对现有配置执行现代/旧 CLI 双形式预检。
- 更新在 `/usr/local/bin` 同目录准备 `0755` binary，检查空间后备份；cutover 先把实际
  target 移入 transaction staging 并核对 digest，再以 no-clobber hardlink 发布新 binary；服务
  操作复用 systemd/OpenRC adapter，保留更新前的运行/停止语义，并以服务状态与
  主进程 binary identity 作为完成门。失败会恢复旧 binary 与原服务状态。
- release archive 的成员列表、元数据、成员数、输出、执行时间和解压空间均有上限；
  服务定义通过同目录临时文件原子发布，并以 marker 区分脚本管理内容与用户自定义内容。
- 持久 journal 要求私有 root-owned 目录与 `0600` 单链接文件；首次创建目录会同步其
  父目录。实际停服边界重新核对 PID、binary inode 与 digest，定时重启则由固定
  root-owned helper append-open 同一 lifecycle lock。
- 更新临时目录的完整 canonical ancestor chain 只允许可信 owner/权限或 root-owned sticky
  目录，并记录 leaf 的 device/inode；
  artifact 操作和清理前均拒绝 identity replacement。激活前再次协调服务状态，避免
  原本 inactive 的 Xray 在下载期间被外部启动后仍替换磁盘 binary。激活和恢复都只接受
  journal 记录的旧/新 digest；cutover 并发出现或崩溃恢复时遇到的外部 binary 会原样保留，
  不会被覆盖或删除，且 transaction evidence 保留供人工判定。
- 每个恢复源会在 no-clobber 发布前核对 digest，损坏的 restore stage 可跳过并回退到
  已验证的 displaced/backup；symlink、目录、hash 失败都按外部冲突处理。即使 journal
  已是 committed/rolled-back，清理前仍须证明 canonical target 与该终态一致，并绑定
  已加载 journal 的 inode。备份保留数在任何算术和 recovery cleanup 前严格验证。
- `ordinary-install`、`channel-update`、`fixed-update` 作为操作意图传入事务，lock 内恢复
  pending state 后重新执行 preserve/no-op/refuse/upgrade/reinstall/downgrade/repair 策略。
  named backup 使用独立 inode；所有 live/recovery 终态清理走同一 finalizer，stage 先
  全量预检，dangling journal symlink 与 runtime identity 冲突均保留现场并失败关闭。
  journal rename 后立即更新 transaction inode binding，commit file/directory sync 的单次
  失败仍可完整回滚；恢复源和 terminal target 同时绑定 digest、owner 与记录 mode。
  `/proc` process-set 检查要求 service MainPID 是唯一 Xray 进程，额外 PID 形成 sticky
  conflict，跨后续 recovery 仍阻止 terminal cleanup；OpenRC 无 pidfile fallback 也复用
  该枚举器，不再依赖 `pgrep`。journal pre-rename payload 改为唯一 `mktemp` 并按 inode
  清理，单次写入失败不会阻塞同 token 的下一次 recovery。
- 脚本创建的 `xray.bak-v*-YYYYMMDD-HHMMSS` 默认保留最近 3 份，不触碰其他备份。
  `Ctrl+C` 等可捕获信号在当前进程内回滚；commit journal 发布窗口会先完成 durable
  commit 再重放信号，避免已提交更新被误回滚。`SIGKILL`/断电留下的持久 transaction
  由下一次 Xray 写操作先恢复和验证，自动恢复失败时保留证据并给出人工恢复命令。

影响范围：Xray 的首次安装、显式版本查询/更新、系统工具菜单、CLI help 和 binary
备份；不改变节点配置、UUID、Reality 密钥、SNI、端口、SS 密码或 sing-box 节点。

兼容性：默认通道仍为 stable；prerelease 仅在用户明确选择时使用。已有健康 Xray
不会在普通节点安装中自动变更；systemd 与 Alpine/OpenRC 均经现有 service adapter。

验证方式：运行 `bash tests/test_xray_release.sh` 覆盖 tag/版本选择、API 完整性、架构
映射与更新决策；运行 `bash tests/test_xray_transaction.sh` 覆盖配置预检、运行/停止两种
初始状态、成功替换、启动健康检查失败后的自动恢复、停服后 TERM 回滚，以及持久
journal 的下一次写操作恢复；并覆盖 commit 信号窗口、状态目录父级同步、旧 binary
竞态、不可信 journal 权限、unsafe/replaced TMPDIR、inactive-to-active 服务竞态、
fresh/update 的 no-clobber cutover、损坏恢复源 fallback、算术型 retention 输入、
锁内意图重验、独立 backup、late stage、live finalizer、dangling journal、commit sync
故障注入、pre-rename payload 重试、OpenRC 无 pidfile fallback、恢复源 mode fallback 与额外 Xray PID，
以及 active/terminal 恢复时遇到外部或非普通 target 的保留行为；随后运行
`bash scripts/build-bundle.sh`、`bash -n proxy-hub.sh`、全部模块与 bundle 语法检查、
仓库完整测试和 `git diff --check`。

## 2026-07-21 — 整合远端节点与安装可靠性改进

- 将远端 Hysteria2 功能适配到模块化架构，并改为复用现有 sing-box，而不是安装
  独立 hysteria 二进制或创建每节点 service。新增 `hysteria2`/`hy2` 协议选择、
  `hy2pt`/`hy2pwd` 参数、安全节点 schema、UDP 端口选择、sing-box inbound、
  IPv4/IPv6 信息、分享链接、二维码、列表、状态、健康检查和删除/卸载同步。
- 修复 `both` 节点仅显示 Vision 二维码：安装完成和 `qr` 命令共用安全二维码分派，
  分别输出 Vision 与 XHTTP，且不恢复旧分支直接 source 节点 env 的注入风险。
- 将 SS2022 安装后的 y/n 提示改为“安装时间同步、只检查准确度、跳过”菜单；
  无时钟权限的容器仅提供检查和跳过，并保留明确的权限说明。
- 安装完成语义收紧为服务健康门：Xray 或 sing-box 配置通过校验并成功启动后，才按
  协议 transport 放行本机端口并显示成功信息。Vision/XHTTP/AnyTLS 用 TCP，
  Hysteria2 用 UDP，Shadowsocks 用 TCP+UDP；服务失败会输出诊断、移除本次节点并
  重建原有配置，避免留下“已安装但不可用”的节点。

影响范围：协议选择、节点 env schema、Xray/sing-box 配置聚合、安装成功/回滚语义、
本机防火墙、二维码与 SS2022 安装后交互。既有 VLESS、Shadowsocks、AnyTLS 节点文件
保持兼容；Hysteria2 新增 `HY2_PASSWORD` 键。

兼容性：`get_share_link` 继续返回单链接，`both` 的双输出只发生在二维码入口；
Hysteria2 使用自签名证书，客户端需接受 `insecure=1`。本机放行不能替代云厂商
安全组，Hysteria2 必须额外开放 UDP 而非同号 TCP。

验证方式：协议/节点 schema 单元测试，sing-box 混合 AnyTLS+Hysteria2 配置测试，
二维码协议矩阵，SS2022 主机/容器菜单矩阵，TCP/UDP 防火墙分派与 Xray/sing-box
启动失败回滚测试；随后重建 manifest/dist，运行仓库完整测试、`bash -n` 和
`git diff --check`。

## 2026-07-20 — 拆分单文件入口

- 将约 7,000 行的单文件实现按安全状态、运行平台、安装器、网络配置、节点命令
  和系统工具等变化维度拆分到有序 `lib/` 模块。
- 保留 `proxy-hub.sh` 作为稳定入口：完整仓库加载本地模块，远程进程替换加载
  经过 manifest、trailer 和 SHA-256 校验的 dist bundle。
- 保留原一行远程命令、CLI 命令、环境变量、节点 env schema 与交互方式。
- 加固临时文件和锁清理：清理范围限定为当前进程拥有且目录 identity 未变化的
  资源；新版入口共享私有 `mkdir` 锁路径，并增加 owner token、目录 identity 与
  锁发布阶段延迟信号；终止时按 PID/start time 冻结、强杀、reap 后台进程树，
  并完成 SSH 安全回滚后才解锁。新旧版本切换要求 quiescent window，禁止在线混跑。
- 为后台任务增加受约束的 PGID + leader start time 边界，持续捕获 TERM handler
  fork 后立即退出留下的 reparent child；成员 scan 后与 signal 前再次复核 leader，
  无法证明归属或 PGID 复用时零误杀并保留锁。
- 将 SSH rollback 迁入私有随机状态目录，恢复、validation、restart、结果持久化
  全成功且同步落盘后才删除 backup；确认/回滚使用原子 phase claim，迟到确认等待
  已开始的回滚而不杀 timer。直接回滚删除 state 后同步清空内存态，避免 cleanup
  误留写锁；退出 cleanup 先等待已 claim 的回滚完成，不把 timer 交给通用进程树
  termination；已进入 critical transaction 的 worker 抵抗整个 PGID 的 TERM/HUP，只有本次
  phase claim 成功者执行恢复。失败状态可幂等重试且阻止提前解锁。
- manifest 与 bundle 改为目标文件系统内双产物可回滚事务；任一步替换失败或 cutover
  收到 HUP/INT/TERM 时恢复两件旧 artifact，避免发布混合 build。
- 增加跨进程 release lock，从源快照到事务清理串行化并发 builder；不可证明的
  rollback/disposal 保留 `uncertain` lock 和 backup，后续构建失败关闭。
- loader/builder 的未发布私有目录加入 identity-bound child EXIT cleanup，验证失败
  不残留本进程创建的目录，路径被替换时也不误删替代物。
- loader 对本地组装、远程语法重建的所有写入显式检查，用 bytes/SHA 拒绝部分
  写入和静默整模块遗漏；最终从只读 FD 执行前再验该 FD 的精确字节。
- 在解析本地 manifest 前校验原始 NUL 与末尾 LF，并把 HUP 纳入 bootstrap 临时目录
  发布窗口的延迟、恢复和重新投递，避免 Bash 解析吞字节或信号打断造成临时目录泄漏。
- 增加本地/远程等价性、bundle 完整性、loader 故障注入、锁并发与 SSH rollback
  事务回归测试，并加入真实 PTY、PGID 复用、整 PGID active rollback TERM/HUP、
  runtime 写失败/静默遗漏、双 generation 并发与双产物发布故障注入。

影响范围：启动与代码装载路径；代理功能和持久化格式不变。

兼容性：只下载根 loader 后运行需要 GitHub 网络；离线运行需要完整 clone，不能
只复制部分模块。

验证方式：仓库测试套件、`bash -n`、bundle 可复现构建、`git diff --check`，以及
固定 commit SHA 与移动 `main` 两阶段远程 smoke test。

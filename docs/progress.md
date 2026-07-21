# 变更记录

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

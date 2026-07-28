# 当前未解决事项

## Xray journal payload 在无法取得 inode 时可能残留

- 严重性：low
- 影响范围：Xray 更新或崩溃恢复写入持久 transaction journal 的 pre-rename 阶段。
- 触发条件：state 目录内 `mktemp` 已成功，但紧随其后的 `stat` 因瞬时 I/O 或文件系统
  故障无法读取新 payload 的 device/inode 或 metadata。
- 影响：私有 root-owned state 目录内可能留下一个随机名空 payload；它不复用固定名称、
  不会阻塞同 token 的后续恢复，也不会被当作有效 journal。
- 临时缓解：修复文件系统/I/O 故障后，确认没有 Xray lifecycle 操作运行；仅删除
  `/var/lib/proxy-hub/xray/.xray-update-state.*.payload.*` 中不属于有效 journal、且 owner
  与 inode 已人工核实的普通单链接文件。

## 云平台安全组仍需按 transport 人工放行

- 严重性：low
- 影响范围：所有新增节点，尤其只监听 UDP/QUIC 的 Hysteria2。
- 触发条件：脚本已放行来宾系统内的 iptables/ip6tables、firewalld 或 ufw，但云厂商
  security group、网络 ACL 或上游防火墙仍拒绝对应端口/transport。
- 影响：服务和本机监听健康，外部客户端仍无法连接；只为 Hysteria2 开放同号 TCP
  不会放行其 UDP 流量。
- 临时缓解：在云控制台按节点协议显式开放端口；Vision/XHTTP/AnyTLS 使用 TCP，
  Hysteria2 使用 UDP，Shadowsocks 同时开放 TCP 与 UDP。

## "仅 IPv4" 档不是 socket 级强制

- 严重性：low
- 影响范围：网络栈设置为 `v4` 时的全部 inbound（Xray 与 sing-box）。
- 触发条件：主机同时具备 IPv4 与 IPv6 地址。
- 影响：`v4` 档只把出站域名解析、SNI 测速与分享链接收敛到 IPv4，监听仍停在通配
  地址，而通配地址在 Linux 上是双栈 socket，因此该端口依旧可以被 IPv6 客户端连上。
  真正只监听 IPv4 需要 bind 具体网卡地址，但 NAT 型云主机（Oracle/AWS/GCP 等）的
  公网地址并不在网卡上，脚本据此 bind 会让服务直接无法启动，代价高于收益。
  与之相对，`v6` 档通过 `sockopt.v6only` 做了真正的 socket 级强制。
- 临时缓解：需要严格拒绝 IPv6 入站时，在主机防火墙用 `ip6tables`/`nft` 丢弃对应
  端口，或在网卡/云安全组层面关闭 IPv6；也可以直接在内核以 `ipv6.disable=1` 启动。
- 说明：sing-box inbound 没有 `v6only` 等价字段，因此 AnyTLS / Hysteria2 在 `v6`
  档同样是双栈绑定，只是不再产出 IPv4 分享链接。

## 构建事务不确定时需人工恢复发布锁

- 严重性：low
- 影响范围：`lib/manifest.sha256` 与 `dist/proxy-hub.bundle.sh` 的构建发布。
- 触发条件：cutover 后 rollback 或 transaction staging 清理无法验证，或进程在
  `uncertain` 阶段被 `SIGKILL`/主机故障终止。
- 影响：`.proxy-hub.release.lock` 保留且不会按死 PID 自动回收，后续构建
  失败关闭，避免在双产物状态不明时继续覆盖。
- 临时缓解：停止全部 builder，保留并检查 `.proxy-hub.*.txn.*` backup，将 manifest
  与 bundle 一起恢复到同一已知 generation 并验证后，再人工移除该锁。

## 写锁在不可捕获退出后可能残留

- 严重性：low
- 影响范围：使用新版每 UID 私有 `write.lock.d` 排他域的写操作。
- 触发条件：进程收到 `SIGKILL`、宿主机崩溃或断电，shell cleanup 无法运行。可捕获的
  INT/TERM/HUP（含 `Ctrl+C`、SSH 断开、终端关闭）已走 cleanup 释放锁，不再触发本项。
- 影响：锁目录可能保留；无法安全证明 stale 时，后续写操作会拒绝启动。
- 临时缓解：为便于恢复，获取写锁失败时脚本会只读诊断记录的 PID——owner 仍存活则提示
  另有实例正在运行，`/proc` 可证明其已退出则判定为残留锁并直接打印可复制的删除命令。
  管理员确认没有 Proxy Hub 写操作运行后，据此人工删除 `/tmp/proxy-hub-<uid>/write.lock.d`。
  诊断仅读取 PID/`/proc`，不会仅凭 PID 自动化删除或接管锁。

## 同 UID 恶意进程不属于锁机制的防护范围

- 严重性：low
- 影响范围：同一 UID 可写锁文件/目录或可向 Proxy Hub 进程发送信号的主机。
- 触发条件：同 UID 的恶意本地进程主动伪造 PID/owner 元数据、持有锁或干扰进程。
- 影响：可能造成拒绝服务或破坏 stale 判定；单实例锁不是针对同 UID 攻击者的安全
  隔离边界。
- 临时缓解：限制 root/运行 UID 的访问，不要在存在不受信任同 UID 代码的宿主机上
  运行管理脚本。

## 无法证明归属的进程组会保留写锁

- 严重性：low
- 影响范围：Proxy Hub 被嵌入一个并非由脚本或其后台 root 领导的既有 process group，
  且终止 cleanup 时仍有后台任务。
- 触发条件：cleanup 无法把后台 root 的 PGID 证明为本脚本专属边界，或观测到 PGID
  leader start time 变化。
- 影响：为避免误杀无关进程或让逃逸 writer 解锁，cleanup 会失败关闭并保留写锁；
  后续写操作会被拒绝。
- 临时缓解：从正常交互 shell、独立 service/process group 启动；确认所有相关任务均
  已退出后，按上文 stale-lock 流程人工清理。

## 无控制终端运行时交互提示会以 unbound variable 中断

- 严重性：low
- 影响范围：全部交互式提示（协议选择、SS 加密方式选择、端口输入、SNI 选择、
  编辑菜单），即 `lib/30_provision_network.sh` 与 `lib/50_node_commands.sh` 中
  形如 `local choice` + `read -r choice </dev/tty` 的读取点。
- 触发条件：进程没有控制终端因而 `/dev/tty` 无法打开，例如以
  `curl ... | bash` 管道方式、在 cron/systemd/CI 等非交互上下文中运行。
- 影响：`read` 因重定向失败而从未赋值，脚本在 `set -u` 下以
  `choice: unbound variable` 之类的信息终止。属于失败关闭：终止发生在写入节点
  文件和改动服务之前，不会留下半成品状态，但报错信息不能说明真实原因。
- 临时缓解：从交互式 shell 运行（`bash proxy-hub.sh`，或先下载再执行，而非管道）；
  需要无人值守时用文档记载的环境变量（`proto=`、`name=`、`reym=`、`port=`、
  `ssmethod=` 等）跳过对应提示。
- 说明：此处刻意不给这些变量补默认值——无终端时提示本身也无法显示，静默选取默认
  协议或默认端口会让用户得到一个自己从未选择的节点，比失败关闭更糟。

# 当前未解决事项

## 云平台安全组仍需按 transport 人工放行

- 严重性：low
- 影响范围：所有新增节点，尤其只监听 UDP/QUIC 的 Hysteria2。
- 触发条件：脚本已放行来宾系统内的 iptables/ip6tables、firewalld 或 ufw，但云厂商
  security group、网络 ACL 或上游防火墙仍拒绝对应端口/transport。
- 影响：服务和本机监听健康，外部客户端仍无法连接；只为 Hysteria2 开放同号 TCP
  不会放行其 UDP 流量。
- 临时缓解：在云控制台按节点协议显式开放端口；Vision/XHTTP/AnyTLS 使用 TCP，
  Hysteria2 使用 UDP，Shadowsocks 同时开放 TCP 与 UDP。

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
- 触发条件：进程收到 `SIGKILL`、宿主机崩溃或断电，shell cleanup 无法运行。
- 影响：锁目录可能保留；无法安全证明 stale 时，后续写操作会拒绝启动。
- 临时缓解：确认记录 PID 已不存在且没有 Proxy Hub 写操作运行后，管理员人工删除
  `/tmp/proxy-hub-<uid>/write.lock.d`。不要仅凭 PID 自动化删除。

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

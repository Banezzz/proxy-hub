# 变更记录

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

# HCOM Phase 4 阶段报告

> 报告日期：2026-09-13
>
> 阶段：Phase 4 — 发送调度与旁路监听桥接
>
> 版本身份：App `0.4.0` · Core `0.3.0` · IPC `v2`
>
> 状态：本地实现、自动化回归与 Windows Release 构建/启动检查已完成；真实 USB-UART、已审核虚拟驱动包与真实外部上位机验收未完成。

## 1. 阶段结论

本阶段把用户明确要求的旁路截获实现为“真实 COM + 虚拟 COM 对”桥接，而不是尝试共享打开已经被其他进程独占的真实 COM。HCOM 打开真实 COM 与虚拟对的 HCOM 端；外部软件打开另一端。外部软件写入的数据转发到真实设备，真实设备回包转发回外部软件，两个方向均写入 HCOM 统一日志。

周期发送已移入 Rust Core 的独立线程。它直接按单调时钟调度写入、以共享写锁串行化与手动写入的竞争，UI 不再用 Dart 定时器逐周期下发命令。

## 2. 已完成能力

- 连接配置区可在“直连”和“旁路监听”之间切换；旁路模式显示外部软件端、HCOM 端以及创建端口对动作。
- Core IPC v2 增加 `create_virtual_pair`、`open_monitor`、`virtual_pair` 和 `monitor_state`。
- HCOM 已开始自研 `driver/hcom-vcom/` KMDF 虚拟串口驱动，Core 通过私有 `\\.\HcomVcomCtl` IOCTL 创建端口对，不再查找或调用 com0com。发布构建只从 `driver/hcom-vcom/dist/signed/x64/` 接受经内核策略验证的 HCOM 驱动包；最终用户不需要寻找或安装第三方工具。
- 旁路模式使用 Windows 重叠 I/O（`FILE_FLAG_OVERLAPPED`）分别打开真实 COM 与虚拟 COM；物理→虚拟、虚拟→物理各有独立的 `ABOVE_NORMAL` 工作线程和固定 64KiB 缓冲。读取完成后立即转发，UI 的 6ms 批处理只影响显示，不再位于转发路径。
- 中继写入不调用 `FlushFileBuffers`；`WriteFile` 交给内核驱动排队。UI/日志事件使用有界队列，若消费者跟不上会在下一条 RX/TX 显示事件携带 `droppedBytes`，并发出 `backpressure`。
- Core 在旁路模式分别读取真实 COM 与虚拟 COM：虚拟端输入转发为 TX，真实端输入转发为 RX；任一读取或转发错误都会停止会话、停止定时任务并明确上报错误。
- 旁路模式禁止 `write_data` 与 `start_periodic`，避免 HCOM 成为外部程序之外的第二发送方。
- `start_periodic` 使用独立 Rust 线程、立即首发、`park_timeout` 等待下一个周期；关闭端口、停止周期或写失败会停止并 join 该线程。
- 新增 Flutter 组件回归，确认虚拟 COM 桥接配置流程可见；Core 新增 COM 名称规范化单元测试。

## 3. 验证记录

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| Rust Core 测试 | 通过 | `cargo test --manifest-path core/Cargo.toml`：6/6 |
| Flutter 组件测试 | 通过 | `flutter test --no-pub`：33/33 |
| Flutter 静态分析 | 通过 | `flutter analyze --no-pub`：No issues found |
| Windows Release | 通过 | `flutter build windows --release --no-tree-shake-icons` 成功；Release `hcom.exe` 启动后 `Responding=True`；Release Core 回应 IPC v2 `ready` |
| 重叠 I/O 旁路会话打开/关闭 | 通过 | Release Core 在本机 `COM29` / `COM30` 回环对上以重叠句柄打开并正常 `close_port`；未写入数据 |
| HCOM VCOM 驱动构建/打包 | 通过 | WDK 10.0.26100，Debug/Release x64 零警告编译；Release 包经 Inf2Cat signability 检查，尚未获得 Microsoft 正式签名 |
| 虚拟端口创建与桥接 | 待 HIL | Core 已切换为调用 HCOM 自研控制设备；尚未安装/加载驱动，未做真实 USB-UART 与外部串口软件组合验收 |
| 直连 vs 中继差值测试 | 已实现，待实测 | `tool/perftest/` 新增 T9，要求显式提供真实回环和已创建虚拟端口对，报告 P50/P95/P99 差值与 UI 背压丢弃字节 |

## 4. 使用方式与边界

1. 安装正式 HCOM 发行包；该发行包必须已部署经审核的虚拟串口驱动，用户无需自行寻找第三方驱动。若 Windows 要求授权，按系统提示完成即可。
2. 在 HCOM 选择“旁路监听”，填写一对未占用的 COM 名称并创建端口对。
3. 选择真实设备 COM，点击“启动旁路监听”。
4. 外部软件连接“外部软件连接端”；HCOM 使用“HCOM 连接端”并把双向字节流转发到真实设备。

Windows 用户态程序无法绕过某个外部程序对真实 COM 的独占打开；正确顺序必须是 HCOM 先打开真实 COM，再让外部程序连接虚拟端。虚拟端口仍是内核驱动能力，HCOM 负责把经过签名和授权审核的驱动包随发行物集成；这不是 Flutter 或 Rust 用户态代码可以替代的部分。

## 5. 未完成项

- 字段填充发送和模板绑定仍未完成。
- 条件 / 脚本化发送仍未定义稳定 IPC 契约。
- HCOM VCOM 仍须完成端口枚举/删除、取消 I/O、Driver Verifier、真实外部上位机与 8 小时 soak；之后提交 Microsoft Hardware Dev Center attestation/WHQL。正式签名包必须放入 `driver/hcom-vcom/dist/signed/x64/` 才能生成带旁路监听能力的发行包。
- 尚未以真实 USB-UART、真实外部软件和已审核虚拟端口驱动完成双向回环、异常拔插、并发写入和长期稳定性验收。
- 8 小时连续运行指标未达成，不能以自动测试或 Release 启动替代。

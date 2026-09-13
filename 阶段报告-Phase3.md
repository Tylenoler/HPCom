# HCOM Phase 3 阶段报告

> 报告日期：2026-09-13
>
> 阶段：Phase 3 — 协议帧定义、校验与字段解析
>
> 版本身份：App `0.3.2` · Core `0.2.0` · IPC `v1`
> 状态：本地实现、自动化回归与 Windows Release 已完成；长期与实机验收未完成。

## 1. 阶段结论

Phase 3 在既有 Flutter / Rust 子进程 NDJSON 边界上，完成了可编辑协议帧、校验计算与字段解析能力。Rust Core 仍只承担 Windows COM 传输，Flutter 负责用户模板的验证、拆解和渲染，避免把尚不稳定的业务协议固化到串口 I/O 层。

`0.3.2` 同时完成稳定性与体验修订：字段解析改为接收时缓存、接收列表批量刷新；校验模块、发送与接收工作区按 Material 3 规则完善响应式布局与容器变换动效。

## 2. 已完成能力

### 2.1 协议帧与字段解析

- 新增 `lib/models/frame_protocol.dart`：帧模板、字段和可移植 JSON 模型，以及无副作用的单帧解析器。
- 帧定义器支持添加、编辑、删除和拖拽排序字段；字段类型包括帧头、长度、数据域、整数、校验和帧尾。
- 支持固定 HEX 帧头/帧尾、长度字段驱动数据域、大小端数值、SUM-8 与 CRC-16/MODBUS 校验。
- 支持 HCOM 模板 JSON 导入/导出，导入后立即应用到右侧“字段”Dock。
- 接收区在 HEX 原始与文本原始间切换；字段 Dock 显示 RX/TX、时间、字段 HEX、数值、解析状态和失败原因。

### 2.2 校验模块与交互体验

- “校验模块”作为主窗口内可拖动、可缩小的浮动面板；缩小后本会话数据保留，关闭应用后清除。
- 提供常用 CRC、校验与摘要算法，以及自定义 CRC 宽度、多项式、初值、异或输出、输入/输出反射。
- 计算结果同时显示校验值与完整帧，支持复制完整帧或直接填入主发送框。
- 新增固定拖动区、始终可见的底部操作栏、小屏尺寸约束、恢复默认位置与窗口边界修正。
- 设置、关于、时区、帧定义器、字段编辑、删除确认和校验浮动面板均采用 MD3 容器变换：圆角、色彩、阴影、透明度与缩放连续过渡。

### 2.3 性能、布局与发布身份

- 接收事件约每 33 ms 批量提交 UI，避免高速串口逐条触发整页重绘。
- 新记录进入时仅解析一次并写入 `_parsedEntries` 缓存；切换帧模板时才统一重算，最多保留 5000 条日志及对应缓存。
- 发送卡片改为四角圆角；底部传输指标在宽屏居中、构建身份靠右，窄屏自动换行而不溢出。
- 关于页显示 App、Core、IPC、Git 提交和构建时间。
- 接入用户提供 SVG 作为应用内 Logo；Windows `app_icon.ico` 由该 SVG 完整渲染生成，并嵌入 Release EXE 的应用/任务栏资源。
- 新增 `scripts/build_release.ps1`：清理、依赖解析、格式检查、分析、Flutter/Rust 测试、Release 构建、产物新鲜度、启动响应和 SHA256 任一步失败即终止，只有全部成功才输出 `BUILD SUCCEEDED`。

## 3. 验证记录

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| Flutter 静态分析 | 通过 | `flutter analyze --no-pub`：No issues found |
| Flutter 组件测试 | 通过 | `flutter test --no-pub test/widget_test.dart`：32/32 |
| Rust Core 测试 | 通过 | `cargo test --manifest-path core/Cargo.toml`：5/5 |
| Windows Release | 通过 | `flutter build windows --release --no-tree-shake-icons` 成功；`hcom.exe` 启动后 `Responding=True` |
| 发布完整性 | 通过 | Release 目录生成 `SHA256SUMS.txt`；关于页可读取编译注入的构建身份 |
| 短程虚拟串口回环 | 部分通过 | COM29 ↔ COM30 的 T0–T5、T7 通过；IPC P95 约 1 ms，32 KB 回环零丢包 |

短程性能台的 T6（20 ms 定时调度）记录到最大偏差约 12 ms；该项测量的是宿主调用侧，不等同于 Core 的高精度定时能力。

## 4. 已知边界与未完成验收

- 8 小时持续收发测试按请求暂停，未达到长期稳定性验收；不应以短程压力或 Release 启动替代。
- 高频持续发送期间触发模拟断开/重连时，`close_port` 可能等待 Core 事件超时。独立开关测试可通过，但该组合路径尚未修复。
- 仍需使用真实 USB-UART、真实协议模板，验证连续收发、跨批次分包、拔插重连、实时保存和内存长期稳定性。
- 用户提供的 SVG 含 Flutter SVG 渲染器尚不支持的 `filter` 元素；主体矢量图可用。若需像原文件一样呈现全部滤镜细节，应额外提供/导出兼容 SVG。

## 5. 后续建议

1. 修复高频写入下 `close_port` 的队列/响应超时，再把模拟重连纳入长期测试。
2. 恢复不带持续重连的 8 小时收发与资源监测，记录内存、吞吐、丢包和错误数。
3. 使用目标设备与真实模板完成实机协议验收后，再决定是否进入 Phase 4 的发送面板深化。

## 6. 发布文件

- 主界面与动效：`lib/screens/workbench_screen.dart`
- 帧模型与解析：`lib/models/frame_protocol.dart`
- 组件回归：`test/widget_test.dart`
- 发布脚本：`scripts/build_release.ps1`
- 性能台：`tool/perftest/perftest.dart`
- IPC 契约：`protocol/stdio-ndjson.md`

# HCOM Phase 1 阶段报告

> 报告日期：2026-09-11  
> 阶段：Phase 1 — 框架基座 + 设计系统  
> 当前版本：`0.0.1`  
> 对应提交：`3249507 feat: implement HCOM Phase 1 workbench`

## 结论

Phase 1 的可运行基座已经完成：Windows Flutter 桌面壳、Material 3 设计系统、Rust Core 的标准输入输出 IPC 边界、核心工作台布局和基础交互均已落地，并已构建出 Windows Release 产物。

本阶段的目标是建立可持续迭代的应用骨架，而不是完成真实串口通信或协议解析。因此，当前端口、收发数据和部分数据视图仍是演示数据或界面占位；真实 COM 通信从 Phase 2 开始。

## 本阶段完成内容

### 1. 应用框架与 Windows 交付

- 建立 Flutter Windows 桌面应用，应用版本为 `0.0.1+1`。
- 建立 Rust Core 独立可执行程序 `hcom-core.exe`。
- Windows 构建流程会将 Rust Core 部署到 `hcom.exe` 同级目录，供 Flutter 子进程启动。
- 增加本地初始化/校验脚本：`scripts/bootstrap.ps1`；`-Build` 可依次校验 Flutter、Rust 并构建 Release。
- 应用图标、窗口图标与任务栏图标使用 `Image/LOGO.png` 生成的 Windows ICO 资源。

### 2. Flutter ↔ Rust IPC 边界

- 采用子进程 `stdio` 上的 UTF-8 NDJSON（一行一个 JSON 对象）作为 Phase 1 固定通信方式。
- Flutter 侧已实现 Core 启动、事件流解析、`hello` / `ping` 指令发送和进程清理。
- Rust Core 已实现 `ready`、`connection_state`、`pong` 与未支持指令的 `error` 事件。
- 协议契约已记录于 `protocol/stdio-ndjson.md`，为 Phase 2 的强类型 COM 命令和吞吐量策略预留扩展位。

### 3. Material 3 工作台与主题

- 按 `设计规范.md` 落地深色默认与浅色切换的 Material 3 ColorScheme。
- 完成单窗口三区主干：端口配置区、数据流视图、发送面板；两侧为 M3 悬浮胶囊 Navigation Rail。
- 完成顶部工具栏、连接状态 Chip、状态栏、Snackbar 反馈与应用版本显示。
- 使用 `Roboto` 作为界面字体、`Roboto Mono` 用于 HEX、时间戳及端口参数。
- 实现用户确认的动效：
  - Rail 选中胶囊：250ms，`Easing.emphasizedDecelerate`；
  - Tab 指示条：200ms，`Easing.standard`；
  - 深浅主题切换：200ms；
  - 连接 Chip 颜色过渡与一次轻微脉冲；
  - 发送面板展开：`AnimatedSize + FadeTransition`，200ms；
  - Snackbar：Material 3 原生浮出。

### 4. 串口配置与数据流界面

- 串口选择框自适应宽度（220 / 250 / 300px），并展示端口、设备描述与图标。
- 设备标识卡完整显示设备描述及硬件 ID；悬停仍可显示硬件 ID。串口选择卡本身不显示悬停信息。
- 波特率、数据位、停止位、校验和流控在断开状态下均可选择；波特率按升序提供 `9600`、`38400`、`57600`、`115200`、`921600`。
- 下拉菜单统一为 16px 圆角、零菜单内边距、选中行整行铺满。
- 实现 HEX 原始、字段解析、时间轴、统计四个 Tab；四个 Tab 均为仅上侧 12px 圆角、下侧直角衔接内容区的样式。
- HEX 视图展示 RX/TX 方向标识、时间戳、HEX 内容和帧标签；发送操作会插入 TX 预览项。

### 5. 发送面板与工具交互

- 实现顺序 / 循环 / 触发三种发送模式的界面选择。
- 提供演示指令队列、上移/下移/删除入口、自由 HEX/文本输入以及“加入队列”“发送”操作反馈。
- 顶部打开、保存、导入、导出、清除等工具按钮采用独立的 M3 tonal 圆形按钮，按钮间保留 8px 间距。

## 已完成的设计细节修正

- 左右侧栏由嵌套样式调整为单一全圆胶囊选中态。
- 全部下拉菜单统一圆角，并修复选中灰色底未整行覆盖的问题。
- 修复通信参数不能切换的问题，调整波特率排序。
- 顶部工具按钮增加间距，避免视觉粘连。
- 设备信息显示与悬停行为已细分：设备标识卡保留提示，串口选择卡取消提示。

## 验证记录

在 Windows 开发环境（Flutter `3.47.2` / Dart `3.13.2`，Rust 位于 `D:\HCOM-Rust`）已完成：

- `flutter analyze`：通过，无问题。
- `flutter test`：通过，当前包含工作台渲染与断开状态切换波特率两项 Widget 测试。
- `flutter build windows`：通过，Release 产物位于 `build/windows/x64/runner/Release/`。
- EXE 图标资源已从 Release `hcom.exe` 提取核验，确认使用新 LOGO；Windows 资源管理器若仍显示旧图标，应按图标缓存问题处理。

## 当前边界与未完成项

下列内容有明确占位或契约，但尚未实现真实业务，不应视为已交付能力：

| 范畴 | 当前状态 | 后续阶段 |
|---|---|---|
| COM 端口扫描、拔插检测与真实硬件 ID | 当前为演示端口数据 | Phase 2 |
| Rust COM 打开、读写与连接状态机 | IPC 骨架已完成，`open_port` / `close_port` 尚为保留指令 | Phase 2 |
| 实时 RX/TX 与连续运行性能验证 | UI 采用演示数据，未进行真实高吞吐量测试 | Phase 2 |
| 帧定义器、自动分帧、CRC/和校验 | 尚未实现 | Phase 3 |
| 字段解析与时间轴的真实内容 | Tab 和占位页已建立 | Phase 3 / 6 |
| 可执行的队列、定时/条件发送、预设 | 当前为 UI 交互预览 | Phase 4 |
| 插件扫描、Manifest 与 Python/Rust 双轨接口 | 尚未实现 | Phase 5 |

## 建议的下一步（Phase 2）

1. 在 Rust Core 接入 Windows COM 枚举与读写，并将扫描结果、设备描述和硬件 ID 以 NDJSON 返回 Flutter。
2. 以 `open_port` / `close_port` 命令完善连接状态机；连接后锁定通信参数，异常与拔插走明确错误事件。
3. 建立 RX/TX 批处理、背压和内存上限策略，再进行持续数据流性能测试。
4. 将 Flutter 的连接 Chip、状态栏计数和 HEX 视图绑定真实 Core 事件。
5. 为 Core 的命令解析、串口错误路径和数据流映射补充自动化测试。

## 仓库状态

- 默认分支：`main`
- 当前提交已推送至：<https://github.com/Tylenoler/HPCom>
- 构建目录、IDE 配置、缓存、日志与 Rust `target` 已由 `.gitignore` 排除，不纳入版本库。

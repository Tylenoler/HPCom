# HCOM — 串口调试助手

> 一个以 **UART 串口通信 + 用户自定义协议帧解析** 为核心的桌面端工程调试工具。
> 插件化架构 · 性能优先 · Material 3 设计 · 面向嵌入式工程师 · 自用与开源同步。

---

## 📖 先读这里

| 文档 | 说明 |
|------|------|
| **[交接说明.md](交接说明.md)** | ⭐ **从这里开始** —— 项目全貌、已冻结决策、当前进度、下一步、接手须知 |
| [产品说明书.md](产品说明书.md) | 产品完整定义：功能 / 架构 / 交互 / 边界 / 里程碑 |
| [设计规范.md](设计规范.md) | 设计系统：Material 3 token / 字体 / 组件 / 布局 / Flutter 对照表 |

## 🎨 UI 原型（可直接打开）

- ✅ **[sketches/002-material3/index.html](sketches/002-material3/index.html)** —— 已采纳的设计基准（Material 3，可交互，深/浅主题切换）
- 🗄️ [sketches/001-material-dark/index.html](sketches/001-material-dark/index.html) —— 早期版本，仅存档

> 查看方式：浏览器直接打开 HTML 文件，无需构建、无依赖。

## 🧭 项目速览

| 维度 | 决策 |
|------|------|
| 核心能力 | 双向 UART 收发 + 用户自定义协议帧解析 |
| UI 前端 | Flutter（Google **Material 3**） |
| 后端 | Rust（串口 + 协议分析，性能优先） |
| 插件体系 | 双轨：普通 Python / 高性能 Rust |
| 目标平台 | Windows 桌面端为主 |
| 通信类型（v1） | 仅 UART / COM |

## 📌 两条底线

1. **写速快** —— 决定能否自用与开源同步推进
2. **不能一卡一卡** —— 调试工具，性能是生命线

## 🛠️ 当前开发入口（已完成 Phase 3）

- Flutter UI 源码：`lib/`
- Rust Core 源码：`core/`
- 前后端 IPC 契约：`protocol/stdio-ndjson.md`（子进程 stdio 上的 NDJSON）
- 本地初始化与校验：`scripts/bootstrap.ps1`；追加 `-Build` 会构建 Rust Core 与 Windows EXE。
- 发布构建：`scripts/build_release.ps1` 会清理缓存、执行分析与测试、构建 Release、验证启动并生成 SHA256 清单。只有所有步骤通过才会输出构建成功。

首次在新机器准备工具链后，执行：

```powershell
.\scripts\bootstrap.ps1 -Build
```

需要 Flutter stable（含 Windows desktop support）与 Rust stable。Core 已实现真实 Windows COM 收发；Phase 3 的帧定义、校验与字段解析在 Flutter 端执行，保持 Rust 的 UART I/O 边界稳定。

## 🏷️ 版本策略

| 组件 | 当前版本 | 说明 |
|------|----------|------|
| App | `0.3.2` | Phase 3 稳定性与体验修订 |
| Core | `0.2.0` | Windows UART 通信内核 |
| IPC | `v1` | Flutter 与 Rust 的 NDJSON 契约 |

应用版本遵循 [SemVer](https://semver.org/)。`0.x` 表示仍在稳定化；新增向后兼容能力升 MINOR，修复升 PATCH，破坏兼容才升 MAJOR。变更历史见 [CHANGELOG.md](CHANGELOG.md)。

## 🔗 相关

- 仓库：`https://github.com/Tylenoler/HCOM`

---

*本项目遵循 project-lifecycle 文档规范（说明书 / 日志 / 结果）。*

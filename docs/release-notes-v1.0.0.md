# HPCom v1.0.0

## English

This is the first public HPCom release for Windows x64.

### Highlights

- Windows UART / COM workbench with live RX/TX viewing in HEX and text modes.
- Configurable serial parameters, manual sending, queue and periodic sending.
- Protocol-frame definitions, checksum validation, and JSON template import/export.
- Updated HPCom branding: Windows executable, taskbar icon, application icon, and theme-aware in-app mark.
- Bilingual README with real application screenshots and step-by-step usage guidance.

### Download and run

Download `HPCom-v1.0.0-windows-x64.zip`, extract all files into one folder, and start `HPCom.exe`. Keep `hcom-core.exe`, `data/`, and the bundled DLL files beside the executable.

### Important scope note

This package has been rebuilt and launch-checked locally. It does not include the signed virtual-COM driver package required for complete monitor-mode distribution; use physical COM ports in this release.

## 中文

这是 HPCom 面向 Windows x64 的首次公开发布。

### 本版重点

- Windows UART / COM 工作台，支持 HEX 与文本方式实时查看 RX/TX 数据。
- 可配置串口参数，支持手动发送、发送队列与周期发送。
- 支持协议帧定义、校验计算与 JSON 模板导入/导出。
- 完成 HPCom 品牌更新：Windows 可执行文件、任务栏图标、应用图标和随主题变化的应用内 Logo。
- 提供包含真实软件截图和完整操作步骤的中英双语 README。

### 下载与运行

下载 `HPCom-v1.0.0-windows-x64.zip`，将全部文件解压到同一目录后运行 `HPCom.exe`。请保留可执行文件旁的 `hcom-core.exe`、`data/` 和随附 DLL 文件。

### 重要范围说明

本包已完成本地干净构建与启动检查，但未包含完整旁路监听模式所需的签名虚拟 COM 驱动包；本版本请使用物理 COM 口。

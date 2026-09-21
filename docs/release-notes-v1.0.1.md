# HPCom v1.0.1

## English

This release fixes the two defects found right after the repository rename, and makes CI verify the Windows package it ships.

### Fixed

- Template-length framing keeps a declared zero-payload frame (`AA 55 00 57 0D`) in one piece instead of splitting it into orphan bytes.
- The custom baud rate prompt no longer clips its helper text: the transform surface was 28 px shorter than its content.

### Changed

- The repository is named `HPCom`; repository links, the in-app About entry and the product documents follow the rename.
- Released under the Apache License 2.0 — see `LICENSE`.
- Continuous integration now resolves Cargo and builds the Windows release package (`flutter build windows`) on every push.

### Download and run

Download `HPCom-v1.0.1-windows-x64.zip`, extract all files into one folder, and start `HPCom.exe`. Keep `hcom-core.exe`, `data/`, and the bundled DLL files beside the executable.

### Scope note

The package was rebuilt from a clean Flutter build, passed `flutter analyze` and the full test suite, and was launch-checked. It does not include the signed virtual-COM driver package required for complete monitor-mode distribution; use physical COM ports in this release.

## 中文

本次发布修掉仓库改名后暴露出来的两个缺陷，并让 CI 真正验证它要交付的 Windows 安装包。

### 修复

- 模板长度分包会把声明 0 字节载荷的合法帧（`AA 55 00 57 0D`）拆成孤儿字节，现已完整成帧。
- 自定义波特率弹窗的提示文字被裁切；弹窗高度此前比内容少 28 px。

### 变更

- 仓库更名为 `HPCom`：仓库链接、应用内「关于」页与产品文档统一改名。
- 采用 Apache License 2.0（见 `LICENSE`）。
- CI 现在会解析 Cargo 并真正执行 Windows 发布包构建。

### 下载与运行

下载 `HPCom-v1.0.1-windows-x64.zip`，将全部文件解压到同一目录后运行 `HPCom.exe`。请保留可执行文件旁的 `hcom-core.exe`、`data/` 和随附 DLL 文件。

### 范围说明

本包已完成干净构建、`flutter analyze` 与完整测试，并通过启动检查。未包含旁路监听模式所需的签名虚拟 COM 驱动包，本版请使用物理 COM 口。

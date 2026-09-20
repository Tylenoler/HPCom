# HCOM VCOM — 自研 Windows 虚拟串口驱动

`hcom-vcom.sys` 是 HCOM 自己拥有的 Windows 内核驱动，用于创建成对的虚拟 COM 端口。它替代任何 `com0com` 或其他第三方运行时依赖。

## 架构

```text
HCOM Core ── DeviceIoControl ── \\.\HcomVcomCtl ── hcom-vcom.sys
                                                     ├─ COM50（外部软件）
                                                     └─ COM51（HCOM 中继）
```

- 控制设备接收创建、删除、枚举端口对的私有 IOCTL；协议定义见 `include/hcom_vcom_public.h`。
- 每个端点实现 Windows 串口必需的 `IRP_MJ_READ`、`IRP_MJ_WRITE` 和 `IOCTL_SERIAL_*` 子集；字节从一端写入后进入另一端的有界环形缓冲。
- HCOM Core 只通过 `\\.\HcomVcomCtl` 创建端口对，绝不调用或查找第三方驱动工具。
- 内核缓冲溢出必须计数并经控制 IOCTL 返回，不能静默丢弃。

## 当前状态

控制协议与 Core 客户端已经接入。WDK 10.0.26100 下 `Debug x64`、`Release x64` 均以 `/W4 /WX` 编译通过；`build.ps1 -Configuration Release` 已能生成经 Inf2Cat 签名能力检查的未签名 `.sys + .inf + .cat` 包。

这只是可审查的工程基线，不是可直接在用户电脑加载的发行驱动。端口枚举兼容性、外部上位机实测、删除/重建、取消 I/O、Driver Verifier 与 8 小时 soak 仍是发布门槛。

## 构建与测试顺序

1. 安装与 Windows SDK 对齐的 Windows Driver Kit（WDK）和 Visual Studio C++ 桌面/驱动组件。
2. 运行 `./build.ps1 -Configuration Release`，生成 `.sys + .inf + .cat` 及供 HCOM 安装器调用的 `hcom-vcom-installer.exe`。该辅助程序仅调用 Windows SetupAPI 注册 `ROOT\HCOMVCOM` 并应用 INF，不依赖 devcon 或 pnputil。
3. 将 `.sys/.inf/.cat` 驱动包提交到 Microsoft Hardware Dev Center 的 attestation/WHQL 流程；下载 Microsoft 签名后的完整包并放入 `dist/signed/x64/`（此目录不提交源码仓库）。`hcom-vcom-installer.exe` 随 HCOM 安装器一并以组织代码签名证书和时间戳签名。
4. 仅在隔离测试机使用专用测试签名流程；绝不让产品安装器开启测试模式、关闭 Secure Boot 或导入开发证书。
5. 用 HCOM 创建端口对；验证外部上位机、HCOM 中继、取消、并发写入和 8 小时 soak。
6. `scripts/build_release.ps1 -RequireVirtualComDriver` 只接受能通过 `signtool verify /kp` 的 HCOM 签名目录；HCOM 安装程序本身另行使用组织的代码签名证书和时间戳签名。

## 发布底线

正式发行包必须包含 `.sys`、`.inf`、`.cat`，并对驱动包和安装程序分别完成签名。未完成签名的驱动不会在普通 Windows 10/11 用户机器上可靠加载；不得要求用户关闭安全策略来使用 HCOM。

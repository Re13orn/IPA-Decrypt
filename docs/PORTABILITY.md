# 兼容性验证

当前版本：**macOS 1.1.0 (11) · iOS 1.0.4 (5)**。本次结果见 [1.1.0 验证记录](validation/2026-11-28-v1.1.0.json)。

## 平台范围

| 平台 | 系统要求 | 当前版本检查 |
| --- | --- | --- |
| macOS | Apple Silicon · macOS 15+ | Release 编译、24 个 Mac 二进制检查；macOS 15.8.2 / arm64 云端启动及离线组件验证通过 |
| iOS | iOS 16+ | Release 编译、真机二进制平台及资源检查通过 |

iOS 真机安装需要适用于目标设备的有效签名。实体新设备上的完整登录、下载、解密与分享流程仍待验收。

## 越狱设备 SSH 验证

Mac 1.0.3 在 iOS 15.7.3 越狱设备上通过 USB / SSH 22 完成 `mobile` 登录及 sudo root 身份验证；已安装 App 的自动连接检测通过。普通命令的二进制往返、后台命令的 root 身份均已验证。本次未启动设备应用或执行凭据提取。

该设备使用 SSH 密码进行 su 认证未通过；单独 root 密码的实际设备验证尚未完成。su 认证及状态流、非终端二进制传输和非 root 拒绝已通过合成测试。

## 本机模型验证

Mac 1.0.2 在本机 Apple Silicon / macOS 26.4.1 完成实际系统授权、注册状态导出、模型恢复、保存及完整解密/明文哈希校验。私有服务验证另覆盖重复模型、覆盖导出、错误许可证拒绝、取消和临时文件清理。记录不包含账户、许可证标识、模型或应用名称。

本机模型验证使用已安装应用构造的验证 IPA，不等同于原始商店下载。与 IPA 解密下载流程的注册状态兼容性仍需按实际 IPA 校验。

## macOS 15 运行验证

[GitHub Actions 验证任务](https://github.com/Re13orn/IPA-Decrypt/actions/runs/45102738839) 在 macOS 15.8.2 / arm64 上下载并校验最终 DMG，复制 App 后检查签名及资源、实际启动 SwiftUI 界面，在空 HOME 且禁止网络的子进程中执行设备证明引擎，并复核运行后的签名；同时验证 Python 加密模块、提取器 CLI、三个 USB 工具及本机模型组件。

该结果不代表已完成用户反馈设备的 macOS 15.6.1 验收，也不覆盖账户登录、下载和真实设备解密。

## 安装包检查

```sh
python3 scripts/verify-installation.py --platform macos '/path/to/IPA 解密.app'
python3 scripts/verify-installation.py --platform ios /path/to/unsigned.ipa
python3 scripts/check-release.py \
  --macos-app '/path/to/IPA 解密.app' \
  --ios-ipa /path/to/unsigned.ipa
```

检查运行资源、执行权限、架构、最低系统声明、动态库引用及已知用户状态文件。Mac 打包自动执行相应检查，iOS 可通过 `bash scripts/build.sh package-ios` 生成已检查的未签名真机包。

## 待验收项目

- 新设备安装、系统签名提示与首次启动。
- App Store / TestFlight 登录及验证码交互。
- IPA 下载进度、重试与完成状态。
- 凭据导入、许可证匹配、解密、导出及局域网分享。
- 重启应用后的记录读取。
- Mac 越狱设备连接与凭据提取。

首次登录组件初始化需要访问 Apple SAP 服务；账户登录及下载还依赖网络、服务状态与相应授权。

[发行版本](https://github.com/Re13orn/IPA-Decrypt/releases/latest) · [安装指南](INSTALLATION.md) · [构建文档](BUILDING.md)

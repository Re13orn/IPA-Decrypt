# 兼容性验证

当前版本：**macOS 1.0.1 (2) · iOS 1.0.0 (1)**。本次结果见 [1.0.1 验证记录](validation/2026-11-20-v1.0.1.json)，iOS 结果见 [1.0.0 验证记录](validation/2026-11-20-v1.0.0.json)。

## 平台范围

| 平台 | 系统要求 | 当前版本检查 |
| --- | --- | --- |
| macOS | Apple Silicon · macOS 15+ | Release 编译、23 个 Mac 二进制检查；macOS 15.8.2 / arm64 云端启动及离线组件验证通过 |
| iOS | iOS 16+ | Release 编译、真机二进制平台及资源检查通过 |

iOS 真机安装需要适用于目标设备的有效签名。实体新设备上的完整登录、下载、解密与分享流程仍待验收。

## macOS 15 运行验证

[GitHub Actions 验证任务](https://github.com/Re13orn/IPA-Decrypt/actions/runs/44711875497) 在 macOS 15.8.2 / arm64 上下载并校验最终 DMG，复制 App 后检查签名及资源、实际启动 SwiftUI 界面，并验证 Python 加密模块、提取器 CLI 与三个 USB 工具。

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

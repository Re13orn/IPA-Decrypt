# 兼容性验证

当前版本：**1.0.0 (1)**。验证结果见 [机器可读记录](validation/2026-11-20-v1.0.0.json)。

## 平台范围

| 平台 | 系统要求 | 当前版本检查 |
| --- | --- | --- |
| macOS | Apple Silicon · macOS 26+ | Release 编译、安装包资源、动态依赖及签名检查通过 |
| iOS | iOS 16+ | Release 编译、真机二进制平台及资源检查通过 |

iOS 真机安装需要适用于目标设备的有效签名。实体新设备上的完整登录、下载、解密与分享流程仍待验收。

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

[发行版本](https://github.com/Re13orn/IPA-Decrypt/releases/tag/v1.0.0) · [安装指南](INSTALLATION.md) · [构建文档](BUILDING.md)

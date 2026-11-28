# IPA 解密

[English](README.md) · [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/Re13orn/IPA-Decrypt)](https://github.com/Re13orn/IPA-Decrypt/releases/latest)
[![平台](https://img.shields.io/badge/platforms-macOS%2015%2B%20%7C%20iOS%2016%2B-blue)](#下载)
[![许可证 GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
[![macOS 兼容性](https://github.com/Re13orn/IPA-Decrypt/actions/workflows/macos-compatibility.yml/badge.svg)](https://github.com/Re13orn/IPA-Decrypt/actions/workflows/macos-compatibility.yml)

**下载 App Store 与 TestFlight 应用，解密并导出 IPA 包。**

支持 **TestFlight 测试应用**与 **App Store 历史版本**。提取并保存 FairPlay 凭据后，可重复解密许可证匹配的多个应用或版本。

[下载 Mac 版](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.9/IPA-Decrypt-macOS-1.0.9-arm64.dmg) · [下载 iOS 版](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.7/IPA-Decrypt-iOS-1.0.3-unsigned.ipa)

### 主要优势

- **App Store + TestFlight**：在同一工具中下载、解密并导出 IPA。
- **历史版本下载**：选择 App Store 提供的旧版本，便于版本回溯与分析。
- **提取一次，重复使用**：保存凭据，后续直接处理匹配的 IPA，无需为每个目标 App 反复在设备上执行运行时砸壳。
- **两条设备路线**：有兼容 Mac，可从本机恢复模型，无需越狱 iPhone；没有 Mac，也可将从越狱 iPhone / iPad 提取的凭据导入 iOS 版使用。

**首次：提取并保存凭据。以后：下载或导入 IPA → 匹配凭据 → 解密 → 导出解密 IPA。**

| 你有什么设备？ | 如何开始 |
| --- | --- |
| **Apple Silicon Mac，无越狱 iPhone** | 从 Mac App Store 安装兼容的 iPhone / iPad App，恢复本机 FairPlay 模型，在 Mac 上解密。 |
| **越狱 iPhone / iPad，无 Mac** | 提取 16 字节 `credential.bin` 后导入 iOS 版，在 iPhone / iPad 上解密。 |
| **已有凭据** | 直接导入文件或十六进制数据；16 字节凭据可在 Mac 与 iOS 版使用。 |

凭据可复用的范围由实际许可证匹配决定；本机模型供 Mac 版使用。TestFlight 需有对应测试访问权限，历史版本以 App Store 返回结果为准。[了解凭据获取方式](docs/CREDENTIALS.md)。

## 下载

| 平台 | App 版本 | 安装包 | 系统要求 |
| --- | --- | --- | --- |
| macOS | **1.0.9** | [Apple Silicon DMG](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.9/IPA-Decrypt-macOS-1.0.9-arm64.dmg) | Apple Silicon · macOS 15+ |
| iOS | **1.0.3** | [未签名 IPA](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.7/IPA-Decrypt-iOS-1.0.3-unsigned.ipa) | iOS 16+ · 安装前需有效签名 |

[所有版本与校验文件](https://github.com/Re13orn/IPA-Decrypt/releases) · [安装指南](docs/INSTALLATION.md)

Mac 当前采用 ad-hoc 签名，**未公证**；文件校验和系统打开方式见安装指南。两端版本独立递增，iOS 1.0.3 安装包保留在发布标签 `v1.0.7` 下。

## 界面预览

### macOS

Mac 1.0.9 实际界面，截图时未登录账户。
应用搜索、地区切换、下载操作及凭据工具入口。

![macOS 应用搜索](docs/images/macos-search.jpg)

<details>
<summary>查看应用详情</summary>

![Mac 应用详情、历史版本入口与截图](docs/images/macos-app-details.jpg)

</details>

### iOS

<table>
  <tr><th>应用搜索</th><th>应用详情</th></tr>
  <tr>
    <td><img src="docs/images/ios-search.png" alt="iOS 应用搜索与结果列表" width="320"></td>
    <td><img src="docs/images/ios-app-details.png" alt="iOS 应用详情与版本选择" width="320"></td>
  </tr>
</table>

iOS 图片用于展示界面，应用信息与布局可能随商店地区和版本变化。

## 主要功能

| 使用流程 | macOS | iOS |
| --- | --- | --- |
| 按名称、App ID、Bundle ID 或链接搜索 App Store | ✓ | ✓ |
| 下载 App Store 与 TestFlight IPA | ✓ | ✓ |
| 选择服务器提供的 App Store 历史版本 | ✓ | ✓ |
| 导入、解密和导出本地 IPA | ✓ | ✓ |
| 导入 16 字节 credential.bin 或 32 位十六进制凭据 | ✓ | ✓ |
| 恢复本机 FairPlay 模型 | ✓ | — |
| 通过 USB / SSH 从越狱设备批量提取、去重凭据 | ✓ | — |
| 导出文件及局域网分享 | ✓ | ✓ |

下载与版本可用性以服务响应及账户授权为准。App Store 与 TestFlight 独立选择账户。凭据按实际许可证匹配，账户标签不能代替校验。

## 开始使用

1. 安装对应平台版本；iOS IPA 需要先完成签名。
2. 选择 App Store / TestFlight 账户，或导入本地 IPA。搜索 App Store 无需登录。
3. 按下表准备匹配的凭据。
4. 下载或导入 IPA，在处理记录中查看结果，导出原始包或解密包。

### 选择凭据来源

| 当前条件 | 获取方式 | 使用位置 |
| --- | --- | --- |
| Mac 已安装兼容的商店 iPhone / iPad App | 恢复并验证本机 FairPlay 模型 | Mac 版 |
| 有开启 SSH 的越狱 iPhone / iPad | 全部提取，再按实际凭据内容去重 | Mac 与 iOS 版，使用 16 字节凭据 |
| 已有 credential.bin 或十六进制文本 | 导入文件，或粘贴 32 位十六进制数据 | Mac 与 iOS 版 |

本机模型与 16 字节凭据是不同格式；模型不能转换为 credential.bin，也不能粘贴到 iOS 的十六进制导入框。详见[凭据使用指南](docs/CREDENTIALS.md)和[常见问题](docs/FAQ.md)。

## 兼容性与验证

Mac 1.0.9 已通过 macOS 15 / arm64 启动、内置组件检查，以及空缓存、禁止网络条件下的 ARM64 设备证明引擎执行；执行后再次校验签名。Apple 登录和下载仍需联网。

iOS 发布物为未签名真机包，新实体设备的首次安装完整流程仍待验收。TestFlight 使用非公开客户端协议，可能受 Apple 服务调整影响。

[兼容性记录](docs/PORTABILITY.md) · [已知问题](docs/KNOWN_ISSUES.md) · [数据与隐私](docs/PRIVACY.md)

## 构建与贡献

使用 Apple Silicon Mac 和 Xcode 工具链。构建前需准备原生库及外部运行资源，源码压缩包本身不包含完整登录运行资源。

```sh
python3 scripts/verify-dependencies.py
bash scripts/test.sh
bash scripts/build.sh macos
bash scripts/build.sh ios
```

[构建文档](docs/BUILDING.md) · [依赖清单](docs/DEPENDENCIES.md) · [贡献指南](CONTRIBUTING.zh-CN.md)

使用问题和功能建议请到 [Discussions](https://github.com/Re13orn/IPA-Decrypt/discussions)；可复现缺陷请[提交 Issue](https://github.com/Re13orn/IPA-Decrypt/issues/new/choose)，提供平台、App 版本、诊断码和操作步骤。请勿提交密码、验证码、会话文件或真实凭据。

## 许可证与致谢

项目采用 [GPL-3.0](LICENSE)。第三方组件保留各自版权与许可，详见[依赖清单](docs/DEPENDENCIES.md)。应用信息组织参考 [ipadn](https://github.com/mengangs/ipadn)，实现说明见[界面设计参考](docs/UI_REFERENCE.md)。

如果项目对你有帮助，欢迎 Star 或反馈使用体验。

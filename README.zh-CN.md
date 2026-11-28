# IPA 解密

[English](README.md) · [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/Re13orn/IPA-Decrypt)](https://github.com/Re13orn/IPA-Decrypt/releases/latest)
[![平台](https://img.shields.io/badge/platforms-macOS%2015%2B%20%7C%20iOS%2016%2B-blue)](#下载)
[![许可证 GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

**下载并解密 App Store 与 TestFlight 应用，导出解密 IPA。**

- **TestFlight**：下载、解密已加入测试的应用。
- **历史版本**：获取 App Store 提供的旧版本。
- **凭据复用**：一次提取，重复解密许可证匹配的应用与版本。
- **两条路线**：Mac 本机模型无需越狱 iPhone；越狱设备提取的凭据可导入 iOS 版使用。

凭据获取方式与适用条件见[使用指南](docs/CREDENTIALS.md)。

## 下载

| 平台 | App 版本 | 安装包 | 系统要求 |
| --- | --- | --- | --- |
| macOS | **1.1.0** | [Apple Silicon DMG](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.1.0/IPA-Decrypt-macOS-1.1.0-arm64.dmg) | Apple Silicon · macOS 15+ |
| iOS | **1.0.4** | [未签名 IPA](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.1.0/IPA-Decrypt-iOS-1.0.4-unsigned.ipa) | iOS 16+ · 安装前需有效签名 |

[所有版本与校验文件](https://github.com/Re13orn/IPA-Decrypt/releases) · [安装指南](docs/INSTALLATION.md)

Mac 当前采用 ad-hoc 签名，**未公证**；文件校验和系统打开方式见安装指南。两端版本独立递增，本次双端安装包均位于发布标签 `v1.1.0` 下。

## 界面预览

### macOS

搜索与下载 · macOS 1.0.9

![macOS 应用搜索](docs/images/macos-search.png)

<details>
<summary>查看应用详情</summary>

![Mac 应用详情、历史版本入口与截图](docs/images/macos-app-details.png)

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

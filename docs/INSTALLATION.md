# 安装与使用

## 系统要求与下载

| 平台 | 系统要求 | 安装附件 |
| --- | --- | --- |
| iOS | iOS 16 及以上 | [IPA-Decrypt-iOS-1.0.3-unsigned.ipa](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.7/IPA-Decrypt-iOS-1.0.3-unsigned.ipa) |
| macOS | Apple Silicon · macOS 15 及以上 | `IPA-Decrypt-macOS-1.0.8-arm64.dmg` |

从 [Releases](https://github.com/Re13orn/IPA-Decrypt/releases) 下载附件与对应的 `SHA256SUMS`，在下载目录执行：

```sh
shasum -a 256 -c SHA256SUMS
```

源码附件为 `IPA-Decrypt-source.zip`，开发环境与资源配置见 [构建文档](BUILDING.md)。

## macOS 安装

1. 打开 DMG，将「IPA 解密.app」拖入「应用程序」。
2. 更新现有版本时，先退出应用，再替换安装。
3. 从「应用程序」启动，按需添加 App Store 或 TestFlight 账户。

安装包内置 Python 与 USB 运行依赖。当前采用 ad-hoc 签名，未完成 Developer ID 公证；确认下载来源与文件校验结果后，可按 [Apple 安装说明](https://support.apple.com/en-us/102445)处理“开发者无法验证”等系统提示。

ZIP 格式候选包解压后采用相同的 App 安装步骤。

## iOS 安装

### IPA 安装

`unsigned.ipa` 为未签名包。使用适用于目标设备的有效证书和描述文件完成签名后安装，开发者模式要求取决于具体部署方式。

相关系统要求见 [开发设备分发](https://developer.apple.com/documentation/xcode/distributing-apps-to-your-development-devices) 与 [开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

### Xcode 部署

1. 按构建文档准备原生依赖与运行资源，打开 `apps/ios/IPALab.xcodeproj`。
2. 选择 `IPALab` Scheme，在 Signing & Capabilities 中设置自己的 Team 与 Bundle ID。
3. 连接并解锁设备，完成设备信任与开发者模式设置。
4. 选择目标设备，构建并运行。

更改 Bundle ID、签名 Team 或访问组可能影响升级及数据访问。

## 首次使用

1. 在账户页添加 App Store 或 TestFlight 账户，并完成所需验证。
2. 搜索应用、选择商店地区并查看详情，或导入本地 IPA。
3. 下载原始包；需要解密时，导入匹配的 FairPlay 凭据。
4. 在处理记录中查看状态，导出原始包、解密包，或开启网页分享。

FairPlay 凭据为 16 字节数据，对应 32 个十六进制字符。支持 `credential.bin` 文件或十六进制导入。账户标签用于组织记录，实际适用性由许可证校验确定。

## Mac 本机提取

1. 在原生 Mac App Store 登录，安装并打开一个 iPhone 或 iPad App。
2. 在「本机凭据提取」页选择验证应用；可设置 Apple ID 管理标签，也可保持未绑定。
3. 点击「提取并验证模型」，在 macOS 系统窗口中完成一次管理员授权。App 不接收或保存管理员密码。
4. 完整恢复及 IPA 解密验证通过后，模型会保存到「FairPlay 凭据」。相同模型按内容去重。
5. 导入或下载 IPA 后选择解密；程序按实际许可证校验模型，无法匹配时仍可使用已有的 16 字节凭据。

本机模型绑定商店注册状态及许可证选择器；同一 Apple ID 的其他下载会话不保证匹配。模型不是 16 字节 `credential.bin`，不能用十六进制凭据入口代替。可在凭据管理中导入、导出或删除模型；原始注册快照及临时验证 IPA 在操作结束后清理。

本机模型恢复取决于注册数据格式和应用许可证；macOS 15+ 的 App 启动支持不代表所有系统注册状态都能恢复。部分旧应用没有明文哈希，此时会显示校验范围，不能视为全部明文校验通过。

## Mac 越狱设备提取

1. 连接并解锁越狱设备，确认 SSH 服务可用。
2. 在设备提取页选择 USB 或网络连接，填写用户名、端口及认证信息。
3. 选择提权方式：自动依次验证 sudo、su，也可直接选择 su。sudo 使用 SSH 当前用户的密码；su 使用 root 密码，可单独填写，留空只尝试 SSH 密码。
4. 执行连接测试，确认实际取得 root 权限，再扫描并提取许可证对应的凭据。
5. 从按内容去重的结果中选择需要导入的凭据。

USB 连接通过端口转发访问设备 SSH 服务；网络连接要求 Mac 与设备可互通。

## 常见问题

| 情况 | 建议操作 |
| --- | --- |
| 未收到验证码 | 使用重发入口或选择受信任手机号，按提示完成验证 |
| TestFlight 登录失败 | 记录诊断阶段码，并检查账户、网络及服务状态 |
| 文件选择器白屏或卡住 | 可使用十六进制导入；系统“文件”服务同时异常时，重启设备后重试 |
| Mac 无法启动 | 核对系统要求、文件校验结果及具体系统提示 |
| IPA 解密失败 | 检查凭据与目标许可证的匹配结果，保留诊断阶段码 |

反馈时请提供应用版本、系统版本、操作来源和脱敏诊断码。更多兼容性信息见 [已知问题](KNOWN_ISSUES.md) 与 [验证记录](PORTABILITY.md)。

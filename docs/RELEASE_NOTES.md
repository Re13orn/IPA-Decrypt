# IPA 解密 1.0.0

**iOS 1.0.0 · macOS 1.0.0**

发布标签：`v1.0.0` · 构建号：`1`

iOS 与 macOS 统一版本号为 `1.0.0`。

[下载本版本](https://github.com/Re13orn/IPA-Decrypt/releases/tag/v1.0.0) · [安装指南](INSTALLATION.md) · [兼容性记录](PORTABILITY.md)

## 主要功能

- App Store、TestFlight 与本地 IPA 的统一处理流程。
- 应用搜索、地区选择、详情预览与历史版本下载。
- 多账户管理、验证码交互及过期 App Store 会话恢复。
- FairPlay 凭据导入、内容去重、账户标签及记录管理。
- IPA 解密、原始包与解密包导出、局域网页面分享。
- Mac 端越狱设备 USB / SSH 连接测试与批量凭据提取。


## 下载附件

| 文件 | 平台与用途 |
| --- | --- |
| `IPA-Decrypt-macOS-1.0.0-arm64.dmg` | Apple Silicon · macOS 26+ |
| `IPA-Decrypt-iOS-1.0.0-unsigned.ipa` | iOS 16+ · 安装前需完成有效签名 |
| `IPA-Decrypt-source.zip` | 当前源码与构建文档 |
| `SHA256SUMS` | 下载附件的 SHA-256 校验值 |

Mac 安装包内置 Python 和 USB 运行依赖，采用 ad-hoc 签名，未公证。源码构建所需的原生库和外部资源配置见 [构建文档](BUILDING.md)。

## 验证与兼容性

已完成双端 Release 构建、内部版本号与构建号核验、安装包资源检查，以及 Mac DMG 挂载、签名与动态依赖检查。实体新设备的完整登录、下载、解密与分享流程仍待验收，详细结果见 [兼容性记录](PORTABILITY.md)。

TestFlight 会话依赖 Apple 客户端协议及服务状态；历史版本和下载权限取决于服务器结果与账户授权。系统文件选择器兼容问题及替代导入方式见 [已知问题](KNOWN_ISSUES.md)。

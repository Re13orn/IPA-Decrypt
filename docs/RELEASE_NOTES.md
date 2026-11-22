# IPA 解密 1.0.8

**macOS 1.0.8 — TestFlight 页面与账户恢复修复**

- 修复空列表及错误状态下顶部账户栏出现大面积留白。
- 账户菜单显示当前账户，账户窗口正确选择 App Store 或 TestFlight 服务。
- 列表失败时显示脱敏诊断；HTTP 401 / 403 提供重新验证入口。

此更新改善错误识别和恢复入口，不会绕过 Apple 的会话验证。保存的会话被拒绝时，仍需重新验证账户。

Mac 下载 `IPA-Decrypt-macOS-1.0.8-arm64.dmg`，要求 Apple Silicon / macOS 15+，采用 ad-hoc 签名，未公证。

iOS 沿用 [1.0.3 安装包](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.7/IPA-Decrypt-iOS-1.0.3-unsigned.ipa)，本次未修改；安装未签名 IPA 前需有效签名。附件含 Mac 安装包、源码与 SHA256SUMS。

# IPA 解密 1.0.7

**macOS 1.0.7 — 本机应用扫描修复**

- 本机凭据提取支持扫描 `/Applications`、`~/Applications` 及其子文件夹，修复应用遗漏。
- 跳过隐藏目录与 App 包内部，按实际路径去重。
- 列表显示检测数量；是否可以提取仍以验证结果为准。

Mac 下载 `IPA-Decrypt-macOS-1.0.7-arm64.dmg`，要求 Apple Silicon / macOS 15+。采用 ad-hoc 签名，未公证。

iOS 沿用 1.0.3，安装包未修改。下载 `IPA-Decrypt-iOS-1.0.3-unsigned.ipa`，要求 iOS 16+，安装前需有效签名。

附件含源码及 SHA256SUMS。详见[凭据指南](https://github.com/Re13orn/IPA-Decrypt/blob/main/docs/CREDENTIALS.md)。

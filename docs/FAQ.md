# 常见问题

[English](en/FAQ.md) · [简体中文](FAQ.md)

## 必须有越狱设备吗？

Mac 本机模型路线无需越狱 iPhone，但需要受支持的 Apple Silicon Mac，以及从 Mac App Store 安装的兼容 iPhone / iPad App。恢复的模型供 Mac 版使用，实际解密仍需匹配 IPA 许可证。

从 iPhone / iPad 提取 16 字节凭据，需要设备已越狱并开启 SSH；也可以直接导入已有凭据。详见[凭据使用指南](CREDENTIALS.md)。

## 本机提取为什么只显示几个应用？

默认扫描 `/Applications`、`~/Applications` 及其子文件夹，仅列出检测到 iOS FairPlay 许可证的应用；其他位置可手动选择。没有固定显示两个或三个的上限。

列表中的应用是验证来源，不是凭据数量。多个应用可能对应相同凭据，检测到许可证也不代表一定能提取成功。

## Mac 本机模型能复制成 32 位十六进制，在 iOS 使用吗？

不能。iOS 的十六进制导入框接受 16 字节数据的 32 位十六进制表示。本机模型结构不同，供 Mac 版使用。界面显示的短指纹用于识别记录，不是凭据本身。

## TestFlight 返回 HTTP 401 是什么原因？

服务拒绝了已保存的会话。请在 TestFlight 账户设置中重新验证，再刷新列表。两种服务独立选账户，切换 App Store 不会同时切换 TestFlight。401 不代表账户没有加入测试。

## 为什么 Mac 和 iOS 版本号不同？

Mac 和 iOS 根据各自改动独立递增版本。本次 v1.1.0 同时包含 Mac 1.1.0 与 iOS 1.0.4，README 分别直链到两端安装包。

## Mac 为什么没有公证？

当前发布包采用 ad-hoc 签名，没有 Developer ID 公证，下载入口旁已说明。核对来源与校验文件后，按 [Apple 安装说明](https://support.apple.com/en-us/102445)处理系统提示。目前没有承诺公证时间。

## 已验证新设备的完整流程吗？

验证记录分别说明安装包检查、离线组件、模拟器和真实账户／设备验收范围。全新实体 iPhone 或 Mac 的首次安装完整流程尚未完成验收。详见[兼容性记录](PORTABILITY.md)。

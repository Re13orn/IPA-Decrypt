# IPA 解密 1.0.9

**macOS 1.0.9 — 设备证明运行库首次初始化修复**

- 随安装包提供固定版本 Unicorn 引擎，首次使用不再从外网下载该运行库。
- 校验归档与动态库 SHA-256，自动恢复缺失或损坏的运行库缓存。
- 明确区分安装包组件缺失、校验失败、缓存写入失败与执行失败。
- 增加空缓存、禁止网络条件下的 ARM64 引擎自检。

此修复覆盖运行库首次下载依赖及缓存准备；Apple 登录与设备注册仍需要网络。系统执行限制等其他原因需结合完整诊断码排查。

Mac 下载 `IPA-Decrypt-macOS-1.0.9-arm64.dmg`，要求 Apple Silicon / macOS 15+，采用 ad-hoc 签名，未公证。

iOS 沿用 [1.0.3 安装包](https://github.com/Re13orn/IPA-Decrypt/releases/download/v1.0.7/IPA-Decrypt-iOS-1.0.3-unsigned.ipa)，本次未修改。附件含 Mac 安装包、源码与 SHA256SUMS。

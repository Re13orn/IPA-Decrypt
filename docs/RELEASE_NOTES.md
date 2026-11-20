# IPA 解密 1.0.2

**Mac 本机 FairPlay 模型支持 · iOS 保持 1.0.0**

## 更新内容

- 新增「本机凭据提取」，通过 macOS 系统管理员授权读取本机 FairPlay 注册状态，无需越狱设备。
- 使用已安装的 iPhone / iPad App 完整验证恢复模型；临时快照与验证文件在操作结束后清理。
- 凭据管理支持本机模型导入、格式识别、内容去重、管理归属、导出与删除。
- 解密按 IPA 的实际许可证匹配模型，保留原有 `credential.bin` 和越狱设备提取流程。

## 使用条件

先在原生 Mac App Store 登录，安装并打开一个 iPhone 或 iPad App。模型适用于匹配的商店注册状态和许可证；相同 Apple ID 不保证不同下载来源的 IPA 都匹配。管理员密码仅由系统授权窗口处理。

## 下载与安装

- `IPA-Decrypt-macOS-1.0.2-arm64.dmg`：Apple Silicon · macOS 15+。
- `IPA-Decrypt-source.zip`：源码、依赖来源与构建文档。
- `SHA256SUMS`：附件校验值。

退出旧版后替换 App，原有账户、凭据和处理记录保留。Mac 版采用 ad-hoc 签名，未完成 Developer ID 公证。

iOS 本次无需更新，继续使用 [1.0.0 的 IPA](https://github.com/Re13orn/IPA-Decrypt/releases/tag/v1.0.0)。

本机注册格式恢复能力与 App 系统要求是两个独立范围；未知格式或不匹配许可证会明确报错。完整验证范围见 [兼容性记录](https://github.com/Re13orn/IPA-Decrypt/blob/main/docs/PORTABILITY.md)。

已通过本机 App 内系统授权与模型恢复、私有服务流程验证，以及 [macOS 15 安装包启动验证](https://github.com/Re13orn/IPA-Decrypt/actions/runs/44718743935)。

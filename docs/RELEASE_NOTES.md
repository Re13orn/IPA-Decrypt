# IPA 解密 1.0.3

**Mac 越狱设备提取兼容性更新 · iOS 保持 1.0.0**

- 修复 rootless 越狱环境中固定调用 `/bin/sh` 导致的提权失败，兼容 bootstrap shell 路径。
- 新增「自动／sudo／su」提权选择。需要直接切换 root 的设备可选择 su。
- root 密码与 SSH 登录密码分开填写，仅用于本次操作，不写入磁盘或命令行参数。
- 连接测试、扫描、提取和后台观察/触发进程统一经过提权，避免连接测试通过后后台进程仍以 mobile 身份运行。
- su 使用远程终端认证；二进制传输独立于终端，保持文件字节不变。
- 保留 Mac 本机模型及原有 16 字节凭据功能。

`mobile / 123456` 只代表一组 SSH 登录信息，不能证明 root 密码相同。自动模式下 su 的 root 密码留空时只尝试 SSH 密码，不额外猜测其他密码。仅当实际 UID 为 0 时才报告提权成功。

下载 `IPA-Decrypt-macOS-1.0.3-arm64.dmg`，退出旧版后替换 App。要求 Apple Silicon / macOS 15+；采用 ad-hoc 签名，未公证。

附件另含源码及 SHA256SUMS。iOS 本次无需更新，继续使用 [1.0.0](https://github.com/Re13orn/IPA-Decrypt/releases/tag/v1.0.0)。

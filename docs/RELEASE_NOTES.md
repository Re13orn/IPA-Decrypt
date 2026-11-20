# IPA 解密 1.0.1

**macOS 兼容性更新 · iOS 保持 1.0.0**

## 更新内容

- Mac 最低系统要求由 macOS 26 降为 macOS 15，支持 Apple Silicon。
- 重新编译主程序、AppleAuth 和 ipatool 原生组件。
- 检查所有内置 Mac 可执行文件及动态库的最低系统要求。
- 增加辅助工具要求高于 App 声明系统版本时的回归检查。

## 下载与安装

- `IPA-Decrypt-macOS-1.0.1-arm64.dmg`：Apple Silicon · macOS 15+。
- `IPA-Decrypt-source.zip`：源码与构建文档。
- `SHA256SUMS`：附件校验值。

退出旧版后，将新版 App 拖入“应用程序”并替换；账户及处理记录保留在原有应用数据目录。

Mac 安装包采用 ad-hoc 签名，未完成 Developer ID 公证。iOS 本次无代码变更，继续使用 [1.0.0 的 IPA](https://github.com/Re13orn/IPA-Decrypt/releases/tag/v1.0.0)。

验证范围见 [兼容性记录](PORTABILITY.md)。

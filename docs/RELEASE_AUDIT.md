# 构建与依赖核实

## 首发记录（1.0.0）

本页保留首次发布时的核实结果；当前平台版本和验证范围见 [PORTABILITY.md](PORTABILITY.md)。

版本：**1.0.0**，构建号：**1**。双端编译与安装包检查结果见 [机器可读记录](validation/2026-11-20-v1.0.0.json)。

| 项目 | 结果 |
| --- | --- |
| iOS Release 编译 | 通过 |
| macOS Release 编译 | 通过 |
| 双端版本与构建号 | `1.0.0 (1)` |
| Mac 安装包、挂载镜像与签名检查 | 通过 |
| iOS 真机包资源与平台检查 | 通过 |
| 固定源码、归档与补丁摘要 | 通过 |
| 实体新设备完整流程 | 待验收 |

原生依赖采用固定源码及摘要校验，当前应用构建复用已由源码重建的原生库。具体环境和覆盖范围见 [兼容性验证](PORTABILITY.md)。

## 依赖记录

- `dependencies/sources.lock.json`：8 套源码树及 7 个归档、补丁或锁定输入。
- `dependencies/go-modules.lock.json`：Go 模块图与导入范围。
- `dependencies/python-runtime.lock.json`：独立 Python 发行版本、下载地址与摘要。
- `dependencies/python-macos-arm64.lock.json`：精确 wheel 与摘要。
- `dependencies/usb-macos-arm64.lock.json`：USB 工具及实际链接文件。
- `dependencies/external-assets.lock.json`：外部运行输入。
- `dependencies/sbom.cdx.json`：组件清单。

来源、原始许可与独立核实状态见 [依赖清单](DEPENDENCIES.md) 及 `dependencies/release-review.json`。固定内容摘要用于识别输入，授权范围与对应源码义务需结合各组件原文核实。

## 检查入口

```sh
python3 scripts/verify-dependencies.py
python3 scripts/check-release.py --macos-app '/path/to/IPA 解密.app' --ios-ipa /path/to/unsigned.ipa
```

源码附件不包含生成库、Python 环境及锁文件列出的外部输入，相关准备步骤见 [构建文档](BUILDING.md)。

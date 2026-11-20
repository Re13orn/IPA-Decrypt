# 固定依赖与许可证据

2026-11-20 核实。保留应用现有 GPL-3.0 许可；此清单不代表已完成所有组合分发许可审查。

| 组件 | 固定来源 | 许可证据 / 状态 |
| --- | --- | --- |
| ipatool | `3e84853e2e5d60540a5022b64895d496910144eb`，含本地补丁 | MIT；生成的 Apple 系统组件 profile 单独排除，不能套用外层 MIT |
| AppleAuth | `98c862f7bebc8283a9b87f1578e703f0765dc81d`，含本地补丁 | MIT，保留上游附属 notices |
| ZIPFoundation | 0.9.20 / `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | MIT；两端快照逐文件比对，仅 Package.swift 为本地调整 |
| fairplay-decrypt | `d81d98b13656c9dbb340f04dd0838137278f44a5` | GPL-3.0；适配代码及原生源码在 Extractor，设备助手需重建 |
| libzip | 1.11.4，源码树哈希锁定 | BSD-3-Clause |
| MbedTLS | 3.6.5，源码压缩包 SHA-256 锁定 | 保留上游许可证及附属 notices |
| nlohmann/json | 3.12.0 / `55f93686c01528224f448c19128836e7df245f72` | MIT，已包含固定 single_include 和原始许可 |
| LZFSE | `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd` | BSD-3-Clause，已包含固定源码，构建不再远程 FetchContent |
| Unicorn | 2.1.4 + 固定 iOS patch | README/COPYING 声明 GPLv2，部分文件标注其他许可；**不能按 Python 包元数据的 BSD 判定引擎许可**。与应用 GPL-3.0-only 静态组合仍需审查 |
| Go | 工具链 go1.26.5，go.mod/go.sum 固定 | 完整模块图记录 202 项；Mac 桥接实际导入 50 项，收集根目录 notices；嵌套第三方代码审查仍需完成 |
| CPython | 3.12.14 / standalone build 20260901，aarch64-apple-darwin | 固定官方发行 URL 与 SHA-256；CPython LICENSE 已保留，独立发行内其他原生库 notices 尚需核齐 |
| cryptography / cffi / pycparser | 50.0.2 / 2.1.1 / 3.12，精确 macOS arm64 wheel | PyPI JSON 哈希与下载字节一致；分别 Apache-2.0 OR BSD-3-Clause、MIT-0、BSD-3-Clause；wheel notices 已保留 |
| USB 工具 / dylib | libimobiledevice 1.4.0、libusbmuxd 2.1.1、libplist 2.7.0、glue 1.3.2、OpenSSL 3.6.3 | 锁定实际链接的 9 个文件；保留 Cellar notices、源包 URL/hash；LGPL/GPL 对应源码等分发义务及新机器引导仍需完成 |

## 锁文件与校验

- `dependencies/sources.lock.json`：8 套源树的确定性摘要、7 个源码归档/patch/Go 锁输入。已补丁快照依靠树摘要验证，revision 用于标识上游基线。
- `dependencies/go-modules.lock.json`：完整模块图及实际导入标记；原始 go.sum 继续负责下载校验。未下载模块没有 root notice 不表示上游没有许可。
- `dependencies/python-runtime.lock.json`：standalone Python 构建、URL、SHA-256，校验值来源为固定 uv 0.12.9 元数据。
- `dependencies/python-macos-arm64.lock.json` / `requirements-macos-arm64.lock`：精确 wheel 和 `--require-hashes`。
- `dependencies/usb-macos-arm64.lock.json`：实际安装字节与源包来源；它不是在其他机器上重建 USB 工具的已验证配方。
- `dependencies/external-assets.lock.json`：13 个未核准公开再分发的本地输入。
- `dependencies/sbom.cdx.json`：CycloneDX 组件清单；不是漏洞扫描或零漏洞证明。

```sh
python3 scripts/verify-dependencies.py
python3 scripts/verify-usb-runtime.py
python3 scripts/check-release.py
```

最后一项校验技术输入并报告维护者继续发布准备的决定，独立核实观察项单独列示；检查成功不代表第三方许可已变更。完整证据与隔离构建结果见 [发布核实报告](RELEASE_AUDIT.md)。第三方原文集中在 `licenses/upstream/`，源树内部的许可证继续保留。

## 不得随公开源码导出的本地输入

固定 [Community-Scripts 提交](https://github.com/ScriptingApp/Community-Scripts/tree/cb67401c795775a10b7623a6d51b7b7479e45f22) 的仓库树及 `.scripting` 内嵌 ZIP 均已取得并检查，未找到对应再分发授权；七项资源与本地字节逐一吻合。除已与 Go 1.26.1 标准桥接字节比对一致、并附 BSD notice 的 `wasm_exec.js` 外，剩余六项在两端均排除：`state-store.mjs`、`sap.wasm`、`crypto-api.mjs`、`unicorn_x86.js`、`amd-generator.mjs`、`crypto-worker.js`。这里是“授权未核实”，不是断言上游绝无许可。

Mac `ipatool/internal/store/profile/data_generated.go` 虽然扩展名是 `.go`，但包含从 AppleMediaServices 和 AMSAccountAuthenticationPlugin 提取、压缩编码的 metadata/pages/plugin，亦排除。它不是可凭外层 MIT 自动批准的普通源码。

本地原件未删除；仅用于显式选择的本地构建验证，不自动下载替代物或将其塞入源码 ZIP。维护者已确认继续推进发布准备；源码导出范围仍按清单执行，独立核实状态保持原样，见 OPEN_SOURCE_READINESS.md。

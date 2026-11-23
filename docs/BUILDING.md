# 构建与测试

## 环境及边界

现有本机验证使用 Apple Silicon、Xcode 26 系列工具链。iOS 最低 16，Mac 工程最低 macOS 15。这是当前工程设置，不表示协议本身只能在这些系统运行。

源码仓库与发布包分开：`apps/` 源码，`.build-work/` 可丢弃构建目录，`dist/` 输出；这两个生成目录不进入 Git。Apple 开发者证书、设备描述文件与真实凭据也不进入仓库。

## 本地已有依赖的快速构建

```sh
bash scripts/build.sh macos
bash scripts/build.sh ios
```

Mac 可执行文件：`.build-work/swift-macos/release/IPADecryptMac`。
iOS 未签名 App：`.build-work/ios/Build/Products/Release-iphoneos/IPADecrypt.app`。

iOS 真机签名由开发者自行在 Xcode 配置 Team / Bundle ID，或用自己的签名工具完成。不要改为维护者的个人 Team 或在仓库提交签名材料。Scheme 暂保留 `IPALab`，无需重命名才能构建。

## 原生库重建

Mac：安装 Go（引导工具链后固定到 go1.26.5）、CMake、Ninja 和 Xcode 等本地构建工具，然后运行：

```sh
python3 apps/macos/Tools/build-core.py --work "$PWD/.build-work/native-macos"
```

从 `apps/macos/ThirdPartySource` 的补丁后快照重建 AppleAuth、ipatool 和本机模型组件 UnfairPlay，写入 Mac Vendor 中的生成库。JSON/LZFSE 均来自固定的仓库内源码，不再读取 Homebrew JSON 头文件或远程 FetchContent。Go 通过 go.mod/go.sum 联网校验下载。完整本机隔离验证与剩余新机器条件见 RELEASE_AUDIT.md。

iOS：

```sh
python3 scripts/build-native-ios.py --work "$PWD/.build-work/native-ios"
```

此入口从与 Mac 一致的锁定补丁快照、固定 MbedTLS/Unicorn 源码包构建 iphoneos/iphonesimulator arm64 库；桥接入口保留 iOS 版本。库输出留在 iOS Vendor，不复制 Mac 二进制。旧 Tools 构建器保留供历史参考，发布核实应使用本入口。

## 不进入源码导出的运行资源

- 两端 NativeStoreRuntime 的六项未决资源及 Mac 编码后的 Apple profile：完整列表、固定哈希与排除理由见 `dependencies/external-assets.lock.json` 和 `docs/DEPENDENCIES.md`。从源码导出本身无法完整运行登录流程；本地验证只能显式从已有本地副本导入，不能将该操作解释为再分发许可。
- `.xcframework`、`libipatool.a`：生成物，使用上述构建器重建。
- `Resources/Extractor/bundle/*.ios`：从 `credential-retrieval/Makefile` 构建，需要 iOS SDK 和 ldid；将 `build/bundle/` 输出复制到运行 bundle。保留 iOS ldid 签名，不能用 Mac codesign 重签。
- `Resources/PythonPackages` 与 standalone Python：Mac 打包运行时，单独准备。
- 测试目录里的 `credential.bin` / IPA 是合成夹具，导出时保留并校验已知哈希；不能用真实文件覆盖。

使用 `python3 scripts/verify-assets.py` 检查当前本地资源与快照是否一致；源码导出后缺失的二进制会明确报 MISSING，这是预期，不等于该源码包可直接完整运行。

## Mac 打包

通过锁文件下载并校验独立 Python 和三个精确 wheel（原生 macOS arm64）：

```sh
python3 scripts/bootstrap-python.py --work "$PWD/.build-work/python-runtime"
```

该目录需全新；失败后可保留 downloads 重新下载校验，已存在的 python/packages 不会覆盖。USB 工具及其 OpenSSL、libplist、glue、libusbmuxd、libimobiledevice 依赖从锁定源码构建，统一目标为 macOS 15 / arm64。先安装 CMake、Ninja、pkg-config、Autoconf、Automake 和 GNU libtool 等构建工具，再执行：

```sh
python3 scripts/bootstrap-usb.py --work "$PWD/.build-work/usb-runtime"
```

打包默认使用 `.build-work/usb-runtime/prefix`；可通过 `IPA_USB_PREFIX` 指定其他同样经过构建的目录。源码下载逐项校验锁文件哈希，打包校验 9 个实际链接文件及构建记录；不依赖 Homebrew 安装的运行库。

```sh
python3 scripts/bootstrap-unicorn.py --work .build-work/store-runtime
export IPA_PYTHON_HOME="$PWD/.build-work/python-runtime/python"
export IPA_PYTHON_PACKAGES="$PWD/.build-work/python-runtime/packages"
bash scripts/build.sh package-macos
```

设备证明运行库在构建时按 SHA-256 锁定下载，随包保留原始 wheel；首次使用从安装包展开，不依赖用户端下载。

输出 `dist/macos/IPA 解密.app`。`IPA_MAC_OUTPUT` 可覆盖输出位置。脚本打包重定位 dylib，并进行本机 ad-hoc 签名；没有 Developer ID 公证。默认不会覆盖 `/Applications`，不会删除用户数据。

## 测试和导出

```sh
bash scripts/test.sh
python3 scripts/verify-assets.py
python3 scripts/export-source.py
```

默认测试只使用合成数据，不连接设备、不登录 Apple，不运行真实 SSH 密码握手测试。需要模拟器的额外测试：

```sh
bash apps/ios/Tools/test-credentials.sh "$PWD/.build-work/ios-tests" booted
bash apps/ios/Tools/test-native-store.sh "$PWD/.build-work/native-store-tests" booted
```

以上额外测试要求相应模拟器已启动；真实登录、完整下载和设备提取需要独立人工验证，不能仅凭合成测试宣布通过。

源码导出为 `dist/IPA-Decrypt-source-preparation.zip`，不含 Git 历史、用户数据、缓存及上述生成资源。它是审阅用源码准备包，未决资源许可未确认前不作为完整开源发布包。

## 缓存隔离重建

准备 macOS arm64、Xcode、Python 3.12+、Go、CMake、Ninja。下述命令工作目录必须为空，输入只来自源码导出策略允许的文件；初始静态库数量必须为零。Go/Clang/Swift 缓存隔离，原生/Swift CLI/测试子进程 sandbox 禁止读取原工作区及 App 用户数据，不修改 HOME。Xcode 自带包清单沙盒，不能嵌套此外层策略，其步骤仅使用新 DerivedData/包缓存。`--device-helpers` 另需安装 ldid。

```sh
python3 scripts/clean-build.py --ios --device-helpers --work /private/tmp/ipa-clean-new \
  --external-assets /absolute/path/to/existing-local-source \
  --allow-unreviewed-local-only
```

外部输入必须完全匹配固定哈希。该选项只用于本地研究构建，不能批准公开分发。省略 `--ios` 只验证 Mac。报告与日志保存在指定 work 目录；这是已有 Mac 上的隔离验证，无法证明全新系统引导成功。

发布检查入口为 `python3 scripts/check-release.py`，用于校验源码、依赖摘要及发布配置。来源核实状态见 `dependencies/release-review.json`。安装包自动附带 `licenses/` 和 `dependencies/`。

## 安装包与新设备验证

Mac 打包已自动检查完整 bundle 的运行资源及动态库引用。iOS 可用 `bash scripts/build.sh package-ios` 生成经过检查的真机未签名 IPA。对最终附件可单独运行：

```sh
python3 scripts/check-release.py --macos-app '/path/to/IPA 解密.app' --ios-ipa /path/to/unsigned.ipa
```

该检查不是新电脑或真机验收的替代品。空白模拟器、包内组件和新设备实体安装的覆盖范围分别记录在 [PORTABILITY.md](PORTABILITY.md)。

## macOS 15 安装包验收

`.github/workflows/macos-compatibility.yml` 可手动指定 Release 标签，在 GitHub 的 macOS 15 / arm64 运行器上下载安装包，核对 DMG 校验值与签名，复制 App 后实际启动 SwiftUI 窗口，并检查包内 Python 加密模块、提取器命令行和 USB 工具。仅验证启动及离线组件，不使用 Apple 账户或真实设备。

```sh
gh workflow run macos-compatibility.yml -f tag=v1.0.9
```

此流程应在发布草稿准备完成后运行，通过后再正式发布。完整业务流程和具体用户机器仍需分别验收。

本机模型服务的可选私有验证程序为 `apps/macos/Tools/Tests/EnrollmentIntegration.swift`。仅在本机提供私有快照和已安装应用作为参数，验证恢复、完整解密、重复模型、覆盖导出、许可证不匹配与取消清理。测试不接收密码，真实快照、模型和验证 IPA 禁止进入仓库或公开日志。

Mac 运行检查包含空 HOME、禁止网络条件下的设备证明引擎执行，不涉及 Apple 账户登录。

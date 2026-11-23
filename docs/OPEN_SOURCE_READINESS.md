# 发布状态

| 项目 | 当前状态 |
| --- | --- |
| 源码仓库 | [Re13orn/IPA-Decrypt](https://github.com/Re13orn/IPA-Decrypt) · 公开 |
| 当前发行 | [v1.0.9](https://github.com/Re13orn/IPA-Decrypt/releases/tag/v1.0.9) · 当前 Mac 发布 |
| 应用版本 | iOS 1.0.3 · macOS 1.0.9 |
| 下载附件 | Mac DMG、源码 ZIP、SHA-256 校验文件；iOS 未签名 IPA 继续链接 v1.0.7 附件 |
| macOS 签名 | ad-hoc，未公证 |
| iOS 签名 | 未签名，安装前需完成有效签名 |

## 构建与验证

已完成固定依赖校验、源码检查、双端编译及安装包检查。新设备运行覆盖及待验收范围见 [兼容性记录](PORTABILITY.md)，详细构建结果见 [核实报告](RELEASE_AUDIT.md)。

```sh
python3 scripts/check-release.py
python3 scripts/export-source.py
```

`check-release.py` 检查技术输入及发布配置。传入安装包参数后，还会检查相应附件的资源和动态依赖。

## 来源与依赖记录

依赖版本、源码摘要、原始许可和 SBOM 分别保存在 `dependencies/`、上游源树及 `licenses/`。部分运行资源来源、组合许可及对应源码义务的独立核实仍有待完成，详情见 [依赖清单](DEPENDENCIES.md) 与 `dependencies/release-review.json`。

## 附件范围

源码附件包含项目源码、文档、固定依赖记录及合成测试资源。生成库、Python 环境及锁文件列出的 13 个外部输入需按构建文档准备；应用安装包包含自身所需的运行资源。

用户数据、账户会话、签名材料和设备资料在源码及发行附件之外独立管理。安全报告渠道说明见 [SECURITY.md](../SECURITY.md)。

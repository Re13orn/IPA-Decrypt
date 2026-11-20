# 架构

| 层 | iOS | macOS |
| --- | --- | --- |
| 界面 | SwiftUI + 系统文件选择器 | SwiftUI / AppKit，侧栏和账户窗口 |
| 应用状态 | App/LocalLab.swift / StoreSessionRecovery.swift | App/LocalLab.swift / StoreSessionRecovery.swift |
| App Store | Go ipatool C bridge + 原生依赖 | 同类 Go bridge，独立 macOS 静态库 |
| TestFlight | NativeStoreLogin / WebKit runtime + AppleAuth | 现有 Mac 可用登录逻辑；没有用 Mac Store 自动恢复替换 TF |
| 许可证与凭据 | CredentialRecord / FairPlay | CredentialRecord / FairPlay / DeviceCredentialModels |
| 设备提取 | 无 | Swift → 内置 Python → USB tunnel / SSH → iOS 原生助手 |

应用展示层新增 `AppCatalog.swift`（公开目录解析/链接规范化）及 `AppDetailView.swift`（系统外观的搜索卡片和详情），两端保持字节一致。公共目录查询不复用私有下载协议，详情按钮交回现有工作区管理认证和下载。

两端目前仍分别持有相近的核心 Swift 文件。本次目录整理没有强行合并协议代码，也没有改变账户、凭据 JSON 或已安装应用标识。下一步共享模块应先围绕纯模型和许可证校验建立兼容测试，之后逐步抽离；平台登录入口保持独立。

凭据流：导入文件/十六进制或设备提取 → 按真实 16 字节去重 → 保存来源、标签 → 对 IPA 内 SINF 进行实际匹配 → 解密并记录验证证据。标签和相同 user/key 选择标识都不能替代内容比较或校验。

任务流：选账户/来源/版本 → 取下载元数据和授权 → 下载原包 → 检查可用凭据 → 解密 → 导出或临时网页共享。失败应保留原包及诊断上下文，后续恢复优化以这一流程为边界。

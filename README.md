# LinYu iOS

淋浴 (LinYu) 的 iOS 客户端。Android 版在 [yehu-imei/linyu](https://github.com/yehu-imei/linyu)。

> **当前状态：空壳验证阶段。**
> 这个仓库现在只做一件事——验证「云端构建 → 自签安装」这条链路能走通。
> 还没有任何业务功能，页面只有一个显示构建信息的占位页。

---

## 为什么用 XcodeGen 而不是提交 .xcodeproj

`.xcodeproj` 是二进制/复杂 XML 工程文件，手写不现实，多人协作时还容易冲突。

这里用 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：工程结构写在 `project.yml` 里，
构建时用 `xcodegen generate` 生成 `.xcodeproj`。

好处：

- 工程配置是**纯文本**，可以 review、可以 diff
- 新增文件**不需要改工程文件**（按目录自动收集）
- **不需要 Mac 也能开发**——Windows 上写 Swift + 改 YAML 即可，工程在云端生成

## 构建（GitHub Actions，免费）

推送到 `main` 会自动构建，也可以在 Actions 页面手动触发（workflow_dispatch）。

产出：Actions → 对应 run → Artifacts → **`LinYu-unsigned-ipa`** → 下载得到 `LinYu-unsigned.ipa`。

构建的是**未签名包**（`CODE_SIGNING_ALLOWED=NO`），因为云端没有你的开发者证书。

## 安装到 iPhone（Windows 即可，不需要 Mac）

1. 下载 [Sideloadly](https://sideloadly.io/)（Windows 版）
2. iPhone 用数据线连电脑
3. 把 `LinYu-unsigned.ipa` 拖进 Sideloadly
4. 填你的 **Apple ID**（免费账号即可）
5. 点 Start

装完后去 iPhone 的 `设置 → 通用 → VPN与设备管理`，信任你的 Apple ID 证书。

### 注意

- **免费 Apple ID 签名的 App 只有 7 天有效期**，过期后打不开，重跑一次 Sideloadly 即可（ipa 可以留着复用）
- 免费账号最多同时存在 3 个自签 App
- 第一次安装可能需要先在同一台电脑上用 AltServer / Sideloadly 配对过设备

## 本地构建（需要 macOS）

```bash
brew install xcodegen
xcodegen generate
open LinYu.xcodeproj
```

## 目录结构

```
.
├── project.yml                  # XcodeGen 工程描述
├── LinYu/
│   ├── LinYuApp.swift           # App 入口
│   └── ContentView.swift        # 占位页（显示版本与设备信息）
└── .github/workflows/ios.yml    # 云端构建
```

`LinYu/Info.plist` 由 XcodeGen 根据 `project.yml` 的 `info.properties` **自动生成**，不要手写。

## 已知限制（做业务功能前必读）

| 限制 | 影响 |
|---|---|
| **CoreBluetooth 拿不到 MAC** | 只能用 `CBPeripheral.identifier`（系统 UUID）。Android 端整套 `MacFormat` / `snCode` 匹配逻辑不能在 iOS 复用，需要改为「连上后读协议帧自报的 MAC」 |
| **模拟器没有蓝牙** | BLE 相关功能只能真机测试 |
| **没有 Mac 时无 SwiftUI Preview** | 改界面只能靠「构建 → 装机 → 看」，迭代很慢 |
| **后台受限** | Android 的 `ShowerWatchService` 那种常驻监控无法照搬 |
| **7 天重签** | 免费账号自签的包需要每周重装一次 |

## 后续计划

详见开发规划书（原生 SwiftUI + CoreBluetooth，先做 TCP 设备 MVP，再迁 BLE 协议）。
第一阶段的关键验证顺序：

1. 这台 iPhone 能否在 12 台同类设备中准确选中目标旧表
2. CoreBluetooth 能否完成 FF00/FF01/FF02 通信
3. 开阀 / 关阀 / 采集 / 结算能否与服务端闭环

## 许可证

[MIT](../linyu-open-source/LICENSE)

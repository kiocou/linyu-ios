# LinYu iOS

淋浴 (LinYu) 的 iOS 客户端。Android 版在 [yehu-imei/linyu](https://github.com/yehu-imei/linyu)。

> **当前状态：功能对齐阶段。**
> 已实现下列模块，仍需逐项验证与 Android 3.1.0 的行为一致性（登录 / 扫描 / 云端与蓝牙开关阀 / 结算 /
> 账单与代扣 / 使用码 / 挤号检测 / MQTT 订单事件 / 背景装扮 / 日志 / 更新检查）。
> 逐条对照见 [`docs/安卓对齐清单.md`](docs/安卓对齐清单.md)，那里同时列了
> iOS 的系统能力边界（后台监控、常驻通知、小组件、应用内安装）。
>
> MQTT 消费数据仅在订单结束时推送，使用中没有实时扣费；以 Android《开发者指南》的明确限制为准。
> 待完善：多设备操作目标和结算并发验证、界面行为对齐、WidgetKit 小组件（暂缓）及真机验收。

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
├── docs/安卓对齐清单.md          # 与 Android 的逐条对照 + 系统边界
├── LinYu/
│   ├── LinYuApp.swift           # App 入口
│   ├── RootView.swift           # 登录态分流 + 主题注入
│   ├── MainTabView.swift        # 三页容器（视差切换 / 弹窗 / Toast）
│   ├── MainScreenView.swift     # 首页（设备列表 / 使用中订单）
│   ├── WalletScreenView.swift   # 钱包（余额 / 趋势 / 账单 / 代扣）
│   ├── UserScreenView.swift     # 我的（卡片排序 / 设置 / 退出）
│   ├── ShowerFlow.swift         # 开阀/关阀/结算编排（对应 MainViewModel）
│   ├── CloudShower.swift        # 云端 4G 通道
│   ├── BleSession.swift         # 蓝牙水表通道（GATT + 帧协议）
│   ├── SettlementEngine.swift   # 结算金额查询与回退
│   ├── ActiveOrderStore.swift   # 活跃订单持久化
│   ├── PendingSettlement.swift  # 待对账 + 7 天复核
│   ├── DeductService.swift      # 未支付账单 + 手动代扣
│   ├── MqttClient.swift         # MQTT 订单事件（手写 3.1.1，无使用中实时扣费）
│   ├── KickWatch.swift          # 挤号检测（25s 心跳）
│   └── ...                      # 其余 UI / 工具（命名与 Android 文件对应）
├── Tests/                       # CI 里直接 swiftc 编译运行的回归检查
└── .github/workflows/ios.yml    # 云端构建（回归检查 → Archive → ipa）
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

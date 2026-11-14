# 🚿 淋浴 (LinYu) · iOS

[![Platform](https://img.shields.io/badge/Platform-iOS%2016%2B-black.svg)](https://developer.apple.com/ios/)
[![Language](https://img.shields.io/badge/Language-Swift-orange.svg)](https://www.swift.org/)
[![UI](https://img.shields.io/badge/UI-SwiftUI-blue.svg)](https://developer.apple.com/xcode/swiftui/)
[![Version](https://img.shields.io/github/v/release/yehu-imei/linyu-ios?label=Version)](https://github.com/yehu-imei/linyu-ios/releases/latest)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/yehu-imei/linyu/blob/master/LICENSE)

趣智校园第三方 iOS 客户端，用于控制校园热水器、查看消费账单。以简洁的界面提供设备操作、消费统计与个性化设置

**⬇️ [下载最新 IPA](https://github.com/yehu-imei/linyu-ios/releases/latest)** · [Gitee 镜像](https://gitee.com/yehu-imei/linyu-ios/releases) · [安装教程](https://github.com/yehu-imei/Guides/blob/main/Tutorial/.ipa%E7%9A%84%E5%AE%89%E8%A3%85.md)

> 支持 iOS 16 及以上，桌面小组件需 iOS 17 及以上。IPA 需要自行签名安装
> Android 版本请前往 [淋浴主仓库](https://github.com/yehu-imei/linyu)

## ✨ 功能

### 🚿 设备控制

- **便捷登录**：短信验证码与密码登录，保存登录状态
- **附近设备**：蓝牙扫描、信号强度显示、扫码选设备与寝室绑定
- **开关热水**：支持云端热水器及兼容的蓝牙水表，提供订单恢复与消费结算
- **使用提醒**：显示设备状态，提供开始、结束及异常情况的通知

### 💰 钱包与账单

- **余额与明细**：查看账户余额、消费记录、账单详情及未支付账单
- **消费趋势**：近七天与本月统计，支持柱形图、折线图切换
- **上次消费**：展示对应设备最近一次消费，方便核对用水支出

### 🧩 桌面小组件

- **小型组件**：设备信息、使用状态、上次消费与开关入口
- **中型组件**：切换设备控制、附近设备和账单页面
- **快捷操作**：打开 App 操作对应设备，或进入设备详情、账单页面

### 🎨 个性化与账户

- **背景装扮**：主页和使用页独立设置背景，支持主题色与透明度调整
- **卡片编辑**：调整卡片顺序，在“我的”和“设置”之间移动
- **账户管理**：个人信息、使用码领取、手机号及密码管理
- **运行日志**：导出日志，方便反馈问题

## 📥 安装

1. 在 [Releases](https://github.com/yehu-imei/linyu-ios/releases/latest) 下载 `linyu-v版本号.ipa`
2. 按照 [iOS 自签安装教程](https://github.com/yehu-imei/Guides/blob/main/Tutorial/.ipa%E7%9A%84%E5%AE%89%E8%A3%85.md) 完成签名与安装
3. 首次使用时按提示开启蓝牙、相机和通知权限

使用桌面小组件时，请将淋浴作为独立 App 安装，并保留小组件扩展及共享权限。导入 LiveContainer 不等同于独立安装，相关系统功能可能受限

更新时建议沿用原签名方式，以便保留应用数据；签名续期按所用工具的说明操作

## 使用说明

- 蓝牙水表需要靠近设备操作；设备兼容性因学校和型号而异
- iOS 不提供常驻后台用水监控，请确认关水成功后再离开设备
- 消费金额以结束后的结算与账单为准，使用中不显示实时扣费
- 小组件刷新由系统调度，显示内容可能存在延迟

## 🛠️ 开发

使用 SwiftUI、CoreBluetooth 与 WidgetKit，工程通过 XcodeGen 管理

在安装 Xcode 的 macOS 上运行：

```bash
brew install xcodegen
xcodegen generate
open LinYu.xcodeproj
```

也可通过仓库的 [GitHub Actions](https://github.com/yehu-imei/linyu-ios/actions/workflows/ios.yml) 构建 IPA。工程配置见 `project.yml`，回归测试位于 `Tests/`

## 📚 文档与反馈

- [更新日志](CHANGELOG.md)
- [应用内精简日志](docs/APP_CHANGELOG.md)
- [问题反馈](https://github.com/yehu-imei/linyu-ios/issues)
- [Android 项目](https://github.com/yehu-imei/linyu) · [Android Gitee 镜像](https://gitee.com/yehu-imei/linyu)
- [iOS Gitee 镜像](https://gitee.com/yehu-imei/linyu-ios)

反馈时请附上应用版本、设备型号、操作步骤和相关日志，并遮盖手机号、验证码等个人信息

## 许可证

沿用原项目的 [MIT 许可证](https://github.com/yehu-imei/linyu/blob/master/LICENSE)

本项目为第三方客户端，与官方趣智校园无隶属关系

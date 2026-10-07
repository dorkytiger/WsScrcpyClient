# iOS / macOS：签名、公证与上架（★ 还没做完的部分）

> **解码与上屏两端都已实现并验证过**（macOS 已实跑截图确认，iOS 在模拟器确认）——
> 实现细节见 [`AGENTS.md`](../AGENTS.md) §15，离线验证见 `tools/run_vt_replay_probe.sh`。
>
> 本文只讲**还没做的那部分**：真机签名、公证分发、App Store 审核，以及已经落地的工程配置清单。
> 它取代了原来的《macOS / iOS 可行性评估》（`docs/platform-feasibility.md`，已删除）：
> 那份文档的结论（两端都可行、共用一份 Swift）已被实现证明，实施计划与工期估算不再有意义，
> 且其"entitlements 缺 `network.client`"的结论**已经过时**（见 §0），留着只会误导。

## 0. 已经落地的工程配置（别再重复检查）

| 项 | 现状（读的是仓库当前文件） |
|---|---|
| macOS entitlements | `DebugProfile.entitlements` 与 `Release.entitlements` 都含 `app-sandbox` + **`network.client`**。**缺 `network.client` 时沙箱会挡掉所有出站连接**（投流与 WebView 都连不出网），而报错很难懂 —— 这条已经加好，别删。Debug 另有 `cs.allow-jit`（Flutter 需要）与 `network.server` |
| iOS `Info.plist` | `ITSAppUsesNonExemptEncryption=false`；`NSAppTransportSecurity.NSAllowsLocalNetworking=true`（局域网明文 `ws://<设备IP>:8886` 直连需要它，比 `NSAllowsArbitraryLoads` 安全得多）；`NSLocalNetworkUsageDescription`（中文文案已写）。⚠️ **这三条都还没在真机上实测**（模拟器走公网 `wss://` 用不到） |
| Swift 文件登记 | 三个文件已在 `ios/Runner.xcodeproj/project.pbxproj` 里（`plutil -lint` 通过、`xcodebuild -list` 能解析、`flutter build ios` 能编译）。共用代码在 `darwin/`，两个 Xcode 工程都用 `path = ../darwin` 引用 —— 改一处两端同时生效 |
| CocoaPods | **硬前置**：`flutter_secure_storage` 还不支持 Swift Package Manager，Flutter 会对它回退到 CocoaPods，没装时 `flutter build ios` 直接以 `CocoaPods not installed or not in valid state` 结束 |
| 应用标识 | 仍是 `flutter create` 默认的 `com.example`（`android/`、`ios/`、`windows/runner/` 三处），**分发/上架前必须改** |

## 1. macOS：分发

- **只在开发机上 `flutter run` 自测**：无需签名配置（ad-hoc 即可）——但要留意
  [§16.1](../AGENTS.md) 那个坑：ad-hoc 签名下 **data protection keychain 用不了**
  （`-34018 errSecMissingEntitlement`），所以密码持久化走了传统钥匙串。
- **分发给别人（不走 Mac App Store）**：macOS 10.15 起要求
  **Developer ID 签名 + Hardened Runtime + 公证**，否则 Gatekeeper 直接拦。
  流程：`codesign`（Developer ID Application 证书，**签完再打 dmg/pkg**）→
  `xcrun notarytool submit --wait` → `xcrun stapler staple`。
  entitlements 不参与签名之外的额外校验，但**必须随签名一起生效**（否则公证过了、运行时照样连不出网）。
- 硬性前置：**Apple Developer Program（99 USD/年）**。

## 2. iOS：真机与上架

### 2.1 签名门槛

| 场景 | 要求 |
|---|---|
| 模拟器 | 无需账号。但**模拟器不保证 VideoToolbox 硬解行为**，解码路径必须真机复验 |
| 免费 Apple ID（Personal Team） | 能装到自己的 iPhone/iPad，但**证书 7 天过期**、要重新部署；本项目用到的能力（网络、安全存储）不需要特殊 entitlement，预计可行 |
| 付费开发者账号 | 正规真机调试 + TestFlight + 上架；99 USD/年 |
| 上架 | App Store Connect 记录、隐私清单（Privacy Manifest）、截图、审核 |

### 2.2 上架前清单

1. `com.example` → 自己的域名（三处）；
2. **隐私清单**（`PrivacyInfo.xcprivacy`）：本项目只连用户自填的服务器、不采集数据，按实际声明；
3. 审核备注里**说清定位**："连接到**用户自有**的 Android 设备 / 自建 ws-scrcpy 服务器"，
   并附自建服务端说明（这直接对应 §2.3 的第 1、2 条风险）；
4. 出口合规问卷（`ITSAppUsesNonExemptEncryption=false` 已填，依据：客户端只用系统 TLS，
   没有自研加密算法；`ws://` 直连本身不加密，也不涉及出口问题）。

### 2.3 ★ 最大的不确定性：App Store 审核（远程控制类）

Apple 的 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) **§4.2.7**
专门针对"远程桌面 / 远程控制"客户端，实质要求通常包括：

1. **应用本身要独立可用**，不能只是"另一个软件的壳"；
2. **只镜像特定软件/服务**容易被拒；本项目是"通用地把 Android 设备镜像/操控出来"，
   方向上更接近被允许的一类 —— 但必须在描述与审核备注里讲清楚；
3. **"仅局域网"曾被当作这类应用的现实约束**（先例：Moonlight iOS 一度收窄为只允许同一 LAN 的 PC）。
   本项目默认连公网 `wss://` 入口，**这是最需要提前查证/沟通的一条，别等提交后才发现**。

对策（成本从低到高）：

- **a.** 审核备注说明"面向用户自有服务器/设备、凭据用户自填"，附自建服务端说明；
- **b.** 提供一个"仅局域网"模式作为默认展示路径，公网入口作为高级选项；
- **c.** 被拒就改走**TestFlight / 自签 / 企业内分发**，不上 App Store ——
  macOS 侧本来就走的这条路（见 §1）。

### 2.4 真机验收清单

照 [`AGENTS.md`](../AGENTS.md) §15.6 那四条走（**别信日志，要截图**）：
① `低延迟模式：kVTDecompressionPropertyKey_RealTime=true 设置结果=0x00000000`；
② `纹理注册成功：来源=…`；③ 心跳 `已解出 / 已喂入` 接近 1:1、`丢弃` 长期为 0；
④ **截图确认画面**并留意色彩（输出是 32BGRA，理论上不会红蓝颠倒，但真机必须看一眼）。

另外两条**只在真机上才知道**的待实测项：`NSAllowsLocalNetworking` 对 `ws://` 是否真的放行
（`AGENTS.md` §4.2e 的老疑问）、iOS 14+ 的**本地网络权限弹窗**会不会出现
（本项目是"出站连到已知 IP"，推断不弹，但必须试）。

## 3. 参考链接

**Apple 官方**
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)（`com.apple.security.network.client`）
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)（§4.2.7 远程桌面）
- [`ITSAppUsesNonExemptEncryption`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/ITSAppUsesNonExemptEncryption)
- [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations)

**审核先例**
- [Moonlight iOS 收窄为"仅 LAN"的那次提交](https://git.anidev.ru/moonlight-stream/moonlight-ios/commit/dbab07838d29388ac9e547905e00836d54c6dd17?files=Limelight%2fNetwork%2fDiscoveryManager.m)
- [The Verge：2020 年 App Store 远程串流条款之争](https://www.theverge.com/2020/9/23/21452029/apple-microsoft-xbox-console-streaming-xcloud-app-store-guidelines)

**本项目**
- 协议实测（改协议前必读）：[`docs/ws-scrcpy-protocol.md`](ws-scrcpy-protocol.md)
- Apple 两端解码实现与踩过的坑：[`AGENTS.md`](../AGENTS.md) §15（纹理注册返回 0、`NSLog` 进不了控制台、编码边界宽高比）
- 历史证据链（Windows 那轮的排查模板）：[`docs/windows-decoder-history.md`](windows-decoder-history.md)

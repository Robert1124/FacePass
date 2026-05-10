# FacePass

![FacePass macOS 菜单栏辅助工具标题图](docs/assets/facepass-readme-header-zh-CN.png)

FacePass 是一个原生 macOS 菜单栏辅助工具，用于在你自己的 Mac 上快速完成本地解锁辅助和密码填充流程。

它的产品想法受 BLEUnlock 启发，但没有使用 BLEUnlock 的代码。FacePass 不使用蓝牙距离判断，而是使用本地摄像头识别 gate。

[官方网站](https://facepass.robertw.me)

[加入 iPhone Companion TestFlight](https://testflight.apple.com/join/p3zBMEBY)

[English README](README.md)

## 它能做什么

FacePass 当前只支持两个狭窄目标，并提供可配置的 provider routing：

- 锁屏辅助：开启后，FacePass 可以在 macOS 已锁定时运行本地人脸识别，识别通过后输入已保存的密码并按 Return。
- 管理员/System Settings 授权提示：FacePass 可以检测被批准范围内的 macOS 授权密码提示，根据 Unlock Mode 运行本地人脸识别或使用已配对 iPhone approval，然后只填入密码值。

对于管理员/System Settings 授权提示，FacePass 不会点击 `OK`、`Continue`、`Modify Settings`、`Login` 或任何确认按钮，也不会按 Return 或提交提示。

锁屏场景中，你可以开启本地识别解锁、iPhone StandBy Unlock，或同时开启两者。Unlock Mode 设置也可以把锁屏解锁交给本地识别，同时允许已配对 iPhone 处理被批准的管理员/System Settings 提示填充。iPhone StandBy Unlock 是独立 provider，不是 Mac 本地识别的补充，也不使用 Mac 摄像头。

## 它不是什么

FacePass 不是 Apple Face ID、Touch ID，也不是 macOS 系统认证的替代品。

FacePass 不支持普通网页或普通 app 的密码输入框。当前范围只限 macOS 锁屏和被批准的 macOS 管理员/System Settings 授权提示。

普通 LocalAuthentication 提示仍然会被拒绝。

## 设置方式

请从[官网设置指南](https://facepass.robertw.me/docs.html#start)开始。它覆盖 DMG 和源码安装、应用内权限、Keychain 密码保存、识别登记和 Unlock Mode 设置。

## iPhone StandBy Unlock

iPhone StandBy Unlock 允许已配对 iPhone approval 触发 FacePass 处理，而不运行 Mac 本地识别。它是一个独立 provider，可以通过 Unlock Mode 路由到锁屏辅助、被批准的管理员/System Settings 提示填充，或两者。

iPhone companion 已开放 external TestFlight 测试：[加入 FacePass TestFlight](https://testflight.apple.com/join/p3zBMEBY)。

- Mac 锁屏时，有效的已配对 iPhone approval 可以唤醒显示器，并使用同一条锁屏密码输入路径。
- Mac 已解锁且存在被批准的管理员/System Settings 提示时，有效的已配对 iPhone approval 只能填入密码值，不点击、不提交、不按 Return。
- iPhone approval 界面会先要求 iPhone 本机解锁/认证，然后才发送签名的本地请求。
- iPhone 永远不会收到 Mac 密码、Mac 人脸数据、Mac 摄像头帧或本地识别结果。
- StandBy Unlock 不使用外部解锁服务器、APNs 解锁路径、WebSocket transport、telemetry、cloud sync 或付费网络服务。

实现和验证细节见 [iPhone StandBy Unlock implementation notes](docs/iphone-standby-unlock.md)。

## 隐私和安全

FacePass 的处理保持在本机。

用户侧隐私政策见[官网隐私页面](https://facepass.robertw.me/privacy.html)。

- 密码只存储在 macOS Keychain。
- 不保存原始摄像头帧、照片或截图。
- 摄像头只在需要时短时间启动。
- 用于锁屏辅助和被批准的管理员/System Settings 提示填充的敏感本地识别 gate 默认最多运行 10 秒。在这个初始窗口内，低于阈值但可用的人脸观察结果可以重试，不会提前让 gate 失败；硬失败仍会立即停止。收集到所需的通过匹配后，识别会立即返回。如果第一次通过匹配出现得较晚，只能通过现有的有界短暂后续采集路径收集剩余所需匹配。摄像头采集仍会在成功、超时、取消或失败后停止。
- 人脸识别模板是本地加密模板数据，不是原始图片。
- 不上传密码、人脸数据、原始摄像头帧、解锁状态、Wi-Fi 细节、显示器标识或环境信号。
- 没有 analytics、telemetry、cloud sync、后台账号服务、外部解锁服务器、APNs 解锁路径、WebSocket 或付费网络服务。
- StandBy Unlock 将已配对 iPhone public-key trust 单独存入 Keychain，使用 replay protection 和 durable counter，并且不会把 Mac 密码或人脸数据发送到 iPhone。

## 从源码构建

请使用[官网从源码构建指南](https://facepass.robertw.me/docs.html#build-from-source)。它覆盖环境要求、clone 命令、验证/构建命令和测试命令。

更深入的本地构建和打包说明见 [Distribution](docs/distribution.md)。本地识别模型 artifact 细节见 [Recognition Model](docs/recognition-model.md)。

## 文档

- [官网文档](https://facepass.robertw.me/docs.html)
- [官网隐私政策](https://facepass.robertw.me/privacy.html)
- [官网开发计划](https://facepass.robertw.me/roadmap.html)
- [Static Website Source](website/)
- [Architecture](docs/architecture.md)
- [Security Model](docs/security-model.md)
- [iPhone StandBy Unlock](docs/iphone-standby-unlock.md)
- [Recognition Model](docs/recognition-model.md)
- [Authorization Prompt Detection](docs/prompt-detection.md)
- [Distribution](docs/distribution.md)
- [Development Roadmap](docs/roadmap.md)
- [Third-Party Notices](NOTICE.md)

## 开发计划

见[官网 FacePass 开发计划](https://facepass.robertw.me/roadmap.html)。后续工作仍保持在本地辅助工具边界内，不会宣称 Face ID、Touch ID、系统生物识别或 macOS 系统认证替代行为。

## License

FacePass 使用 MIT License。见 [LICENSE](LICENSE)。

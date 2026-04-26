# FacePass

![FacePass macOS 菜单栏辅助工具标题图](docs/assets/facepass-readme-header-zh-CN.png)

FacePass 是一个原生 macOS 菜单栏辅助工具，用于在你自己的 Mac 上做本地识别后的锁屏解锁辅助和系统授权密码填充。

它的产品想法受 BLEUnlock 启发，但没有使用 BLEUnlock 的代码。FacePass 不使用蓝牙距离判断，而是使用本地摄像头识别 gate。

[官方网站](https://facepass.robertw.me)

[English README](README.md)

## 它能做什么

FacePass 当前只支持两个目标：

- 锁屏辅助：开启后，FacePass 可以在 macOS 已锁定时运行本地人脸识别，识别通过后输入已保存的密码并按 Return。
- 管理员/System Settings 授权提示：FacePass 可以检测被批准范围内的 macOS 授权密码提示，先运行本地人脸识别，然后只填入密码值。

对于管理员/System Settings 授权提示，FacePass 不会点击 `OK`、`Continue`、`Modify Settings`、`Login` 或任何确认按钮，也不会按 Return 或提交表单。

## 它不是什么

FacePass 不是 Apple Face ID、Touch ID，也不是 macOS 系统认证的替代品。

FacePass 不支持普通网页或普通 app 的密码输入框。当前范围只限 macOS 锁屏和 macOS 管理员/System Settings 授权提示。

## 当前功能

- 原生 macOS 13+ Swift/SwiftUI 菜单栏应用
- 设置窗口：设置、自动化、识别、状态
- 密码只存储在 macOS Keychain
- 首次启动设置流程：Camera 和 Accessibility 权限
- 短时间摄像头会话，只在需要识别时启动
- 单一本地 enrollment template，可包含多条本地 embedding
- 可选锁屏解锁辅助
- 管理员/System Settings 授权提示检测和只填密码值
- 自动操作条件：
  - Wi-Fi 已连接
  - 外接显示器已连接
  - 电源状态
  - 任意/全部条件匹配


## 设置方式

1. 构建并运行 FacePass。
2. 打开菜单栏应用并完成设置。
3. 授予 Camera 权限。
4. 授予 Accessibility 权限。
5. 在 Password 设置中保存你的 Mac 登录密码。FacePass 会把它存入 Keychain，不会再次显示。
6. 在 Recognition 中采集 enrollment samples。
7. 按需要开启锁屏辅助或管理员/System Settings 授权提示处理。

## 隐私和安全

FacePass 的处理保持在本机。

- 密码只存储在 macOS Keychain。
- 不保存原始摄像头帧、照片或截图。
- 摄像头只在需要时短时间启动。
- 人脸识别模板是本地加密模板数据，不是原始图片。
- 不上传人脸数据、密码、解锁状态、Wi-Fi 细节、显示器标识或环境数据。
- 没有 analytics、telemetry、cloud sync 或网络服务。

## 从源码构建

要求：

- macOS 13+
- Xcode command line tools
- Swift 5.9+

运行测试：

```bash
swift test
```

构建并运行：

```bash
./script/setup_and_run.sh
```

这会在本地识别模型 artifact 缺失或无效时先准备它，然后构建、staging，并启动位于 `dist/FacePass.app` 的实体 app bundle。使用 `./script/setup_and_run.sh --verify` 可以准备模型并只验证 app 构建，不启动它。如果 `dist/FacePass.app` 是 symlink 而不是完整 bundle，验证会失败。如果 FileProvider 或 iCloud metadata 导致 `dist` 中的 strict codesign 验证失败，验证流程会发布并报告位于 `~/Library/Caches/FacePass/dist/FacePass.app` 的实体 fallback app。使用 `./script/setup_and_run.sh --logs` 可以启动并 stream FacePass logs。

setup 脚本可能会下载 pinned AuraFace `glintr100.onnx`，验证文件，运行 legacy Core ML 转换路径，并验证生成的 bundled artifact：`Artifacts/Phase8/.../coreml-legacy/glintr100-legacy.mlmodel`。模型 artifact 保留在已忽略的 `Artifacts/` 下，不会提交到仓库。app 本身不会增加网络行为。手动 artifact helper 的高级用法见 [Recognition Model](docs/recognition-model.md)。

## 分发状态

FacePass 当前优先作为源码发布。没有 Apple Developer Program 账号时，你可以本地构建运行、ad-hoc 签名或使用本地 Apple Development 证书，但不能制作 Developer ID notarized 的可信公开下载版。

详见 [Distribution](docs/distribution.md)。

## 文档

- [Architecture](docs/architecture.md)
- [Security Model](docs/security-model.md)
- [Recognition Model](docs/recognition-model.md)
- [Authorization Prompt Detection](docs/prompt-detection.md)
- [Distribution](docs/distribution.md)
- [Development Roadmap](docs/roadmap.md)
- [Third-Party Notices](NOTICE.md)

## 开发计划

下一步计划：

1. 更安全的人脸识别，包括更好的活体/防照片通过能力。
2. 更完整的本地 false accept / false reject 校准。
3. 多角色权限，例如某个已登记人脸只能解锁锁屏，另一个角色可以使用所有已批准的 FacePass 操作。
4. 在具备 Developer ID 凭据后改进签名、公证和分发流程。

## License

FacePass 使用 MIT License。见 [LICENSE](LICENSE)。

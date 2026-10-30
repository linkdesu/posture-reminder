# ADR-0007：纯深度几何与关节来源协议

- **日期**：2026-10-29
- **状态**：已被 ADR-0008 替代（superseded，2026-10-30）
- **替代者**：[ADR-0008：前置摄像头 Vision 关节识别](0008-vision-front-camera-pose.md)。其中“关节由深度轮廓比例推算”的部分作废；“任何构建都不显示摄像头画面”与“点云只来自深度”继续有效，并由 ADR-0008 沿用。

## 背景

0.3 轮为了让孩子在开始专注前看到“镜子”，在主页叠了一层共享 `ARSession` 的摄像头预览，并把“绝不显示 RGB”一条从 ADR-0005 撤销。产品负责人（Link）重新拍板：任何构建都不显示摄像头画面。同时，点云仍由 Vision 关节体积生成，而不是深度数据本身；这与“轮廓/点云只从深度生成”的边界不一致。

## 决策

1. **任何构建都不显示摄像头画面。** 删除 `CameraPreview` 与 `ARSCNView`；主页只有黑底、点云与矢量占位轮廓。不存在 `#if DEBUG` 例外。
2. **几何只来自深度。** 真机输入改为 `DepthCaptureSource`：前置 TrueDepth 的 `AVCaptureDepthDataOutput` 是唯一数据出口。会话必须挂一个 `AVCaptureVideoDataOutput` 才能启动，但该 output 不安装 delegate，本应用不存在读取其缓冲区的代码路径。关节由 `DepthJointSource` 估计：深度分割 → 遮罩 → 关节点与深度平面朝向；点云由 `DepthCloud` 直接采样遮罩内的深度像素。不使用 `ARFrame.capturedImage`、不读取彩色帧像素、不出现 `VNDetectHumanBodyPoseRequest` 或任何 Vision 人体姿态 API。
3. **关节来源是一个可替换的缝。** `JointSource` 协议以 `DepthImage` 为唯一输入；`DepthJointSource` 是深度版实现。后续分支要换关节来源时只替换这个实现，分类器、点云、叠加层与控制器都不改。
4. **诚实标注不可用。** 深度图分不出眼、耳、肘、腕，`DepthJointSource` 不生成它们，而是在 `unavailable` 里列出；调试叠加层把 15 个中文关节名全部画出，可用为实心、不可用为删除线。8 个指标中依赖腕关节的「手到脸」在深度版永远缺测，按既有规则永不越阈。
5. **占位轮廓是矢量。** 尚未检测到人体时，`AvatarView` 用 `Path` 画头、颈、肩、躯干轮廓，不加载任何图片。

## 影响

- 「形象模式」仍旧只控制点云与轮廓的显隐；它不再控制任何摄像头画面。
- 深度版显示名改为「PostureLab 深度版」，Bundle ID 改为 `me.xieal.posturelab.depth`，与 0.3 的 `me.xieal.posturelab` 并存，避免覆盖验收机上的旧版本。
- 深度朝向（俯仰/滚转）来自头部区域的最小二乘平面，精度低于 ARKit 脸位姿；「手到脸」不可用。这些限制必须写进评估报告，而不是被指标表掩盖。
- 隐私边界回到 ADR-0005 的原始条款，并由仓库内的静态自检（`rg 'VNDetectHumanBodyPose|AVCaptureVideoPreviewLayer|capturedImage|AVCaptureVideoDataOutput'`）持续证明。

## 实测记录：`AVCaptureVideoDataOutput` 是否必需（2026-10-29）

本轮尝试按「临时去掉 `videoOutput` → 真机构建/安装/启动 → 抓深度流日志」验证第 2 条里的会话启动假设。**实测未完成**，原因如下：

- 设备 iPhone 13（`00008110-001271181AD3801E`）连接正常，Debug 构建与安装成功（`xcodebuild ... -allowProvisioningUpdates build` → `BUILD SUCCEEDED`；`devicectl device install app` → `App installed`）。
- 探针在 `DepthCaptureSource.start()` 记录 `AVCaptureDevice.authorizationStatus`，得到 `start auth=0`（`notDetermined`）：App 停在系统相机授权弹窗，`requestAccess` 回调未执行，`configure()` 与 `session.startRunning()` 都没有跑到。
- 尝试用临时 XCUITest 点击「允许」以自动授权，但真机 UI 测试 runner 签名失败（`No Accounts`；`me.xieal.posturelab.depth.uitests.xctrunner` 无匹配开发档案；`-allowProvisioningUpdates -allowProvisioningDeviceRegistration` 均无效）。
- 没有绕过授权、没有改系统配置、没有用推断代替实测。`DepthCaptureSource` 已恢复为保留 `videoOutput` 的原实现。

**结论**：第 2 条仍然成立且按保守方式实现（保留 output、不装 delegate、不读缓冲区）；「去掉该 output 是否仍能出深度」待下一次有人可点授权、或 UI 测试 runner 具备开发档案时按 `tmp/verify/r12-adr0007-probe/README.md` 的步骤复测。证据：`tmp/verify/r12-adr0007-probe/`（`probe.txt`、`console-A.txt`、`README.md`）。

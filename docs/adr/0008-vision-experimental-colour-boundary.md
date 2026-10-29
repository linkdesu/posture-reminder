# ADR-0008：Vision 关节来源实验分支的彩色帧边界

- **日期**：2026-10-29
- **状态**：已接受（仅实验分支 `exp/vision-pose`）

## 背景

ADR-0007 为 0.4 深度版定下两条硬边界：任何构建都不显示摄像头画面；轮廓与点云只从深度图生成，且深度版不出现 `VNDetectHumanBodyPoseRequest`。产品负责人要求做一版对照实验：界面、设置、点云、占位轮廓与调试层保持不变，只把关节来源换成 Vision 人体姿态识别，用来比较两版能拿到的关节与 8 个指标的差异。

ADR-0007 的第三条（关节来源是缝）本就是为这种替换写的，因此实验不推翻它的前两条，只把「彩色帧」放进一条可审计的窄通道。

## 决策

1. **彩色帧只在内存中用于一次推理。** `DepthCaptureSource` 的 `AVCaptureVideoDataOutput` 安装 `AVCaptureVideoDataOutputSampleBufferDelegate`，回调里只保存最新一帧的 `CVPixelBuffer` 引用（不拷贝）；每个深度帧（10 Hz）取走该引用并调用 `VisionJointSource`，调用返回后立即置空。任意时刻内存中最多一帧彩色数据，`stop()` 也会清空它。
2. **彩色帧不显示、不保存、不落盘、不写日志。** 没有预览层、没有 `UIImage` 转换、没有 `pngData`/`jpegData`、没有写文件路径；`PostureSample` 只携带关节、24×32 深度格与深度点。`NSCameraUsageDescription` 明确写了「交给 Vision 后立即丢弃」。
3. **点云与占位轮廓仍只来自深度。** `VisionPoseMapping` 内先跑 `DepthSegmentation` 得到人体遮罩、再用 `DepthCloud` 采样点云，与深度版完全一致；关节只借用深度图回答「那个像素多远」。Vision 无权影响点云形状。
4. **关节来源协议做最小扩展。** `JointSource` 增加 `estimate(from:colour:)`，默认实现忽略彩色帧并转发给纯深度方法，所以深度版行为逐位不变（有单测固定）。`VisionJointSource` 用 2D `VNDetectHumanBodyPoseRequest`（不用 3D 版本：单人坐姿下 2D 关节 + 同帧深度足够，且不比单目 3D 回归更差）。
5. **诚实的回退。** Vision 给出 2D 关节；距离只取遮罩内深度中位数，遮罩不存在时所有关节都没有深度（`distance`/`head_forward` 缺测，按既有规则永不越阈）。俯仰复用深度平面拟合（`HeadOrientation`，与深度版同一实现），歪头优先用双眼连线（2D，深度图给不出的信号）；关节置信度低于 0.3 记入 `unavailable`。
6. **可共存安装。** 显示名「PostureLab Vision 版」，Bundle ID `me.xieal.posturelab.vision`（测试 target `.vision.tests` / `.vision.uitests`），版本 0.4（build 4），与 `me.xieal.posturelab.depth` 并存。

## 影响

- 本分支是效果对照实验：只推送、不合入 `feature/depth-pose`、不开 PR。合入前必须由产品负责人决定是否接受彩色帧进入处理链。
- 「手到脸」在 Vision 版可测（腕关节存在），`chinRest` 从深度版的「永不触发」变为「可触发」；阈值与真机稳定性仍需真机校准，报告里如实标注。
- 头部俯仰仍来自深度平面，与 Vision 无关；这是本版与「纯 Vision 3D」设想的差距，报告必须写明。
- 仓库静态自检的期望值随之改变：`VNDetectHumanBodyPose` 与视频 delegate 在实验分支上各有一处预期命中，位置固定在本 ADR、`VisionJointSource` 与 `DepthCaptureSource`，除此之外不得新增。

# Tapito 录屏指南 / Demo recording guide

本页用于补充 README 的真实操作演示。录屏尚未提供，不把任务示例、架构图或模拟回执当作已完成的演示。

## 建议先录三段

| 场景 | 需要拍到的内容 | 建议成片长度 |
| --- | --- | --- |
| 读取信息 | 发出“打开微博，告诉我第一条热搜” → 进入真实榜单 → 回答与榜单一致 | 30–60 秒 |
| 填写文字 | 创建一条专门用于演示的备忘录 → 整段输入 → 返回后确认保存 | 30–60 秒 |
| 学习与复用 | 第一次执行 → 候选审核 → 同类任务再次执行 → 对照实际步骤与耗时 | 60–90 秒 |

以上是剪辑长度建议，**不是性能承诺或实测任务耗时**。如果真实执行更长，可以提供完整录像，并另做标明加速倍率的短版。

操作按钮／灵动岛可另补一段短演示：开始语音 → 下达读取任务 → 执行期间状态 → 完成。需要展示实体操作按钮时，用外部镜头拍摄手机；不要用普通屏幕录制冒充按键证据。

## 拍摄前准备

1. 使用测试内容和测试联系人；读取公开榜单或创建演示备忘录即可。隐藏私人通知、聊天、账号与密钥。
2. 记录 Tapito commit/build、iPhone 型号、iOS、目标 App 版本、模型、普通模式或 Jev 协同模式。Jev 同时标明主模型。
3. 确认模型和设备连接已配置。操作演示可从“连接完成”开始，并明确写出这个前提；首次配对/VPN 授权另外录制上手教程。
4. 若展示已学习流程，先确认是哪个已审核版本；不要把未启用候选描述为自动生效。

## 拍摄时保留的证据

- 用户完整任务、目标 App 的关键页面，以及与任务对应的最终结果。
- 至少一次展开执行记录，展示真实模型／工具耗时，而不是另外编排的倒计时。
- 重试、人工介入和剪辑加速如有发生应标明；不要把等待或失败剪掉后宣称端到端耗时。
- 前后对比保持同类任务、设备、模型及连接条件；分别注明是否已有学习记录。单个例子不扩展成总体成功率或固定提速比例。

## 每段视频附带的信息

```text
任务 / Task:
Tapito commit/build:
iPhone / iOS:
目标 App / Target app version:
执行模式 / Mode:
主模型 / Main model:
Jev 模型（如适用）/ Jev model, if used:
起始条件 / Starting state:
实际总耗时 / Actual elapsed time:
模型请求数 / Model requests:
工具调用数 / Tool calls:
是否复用学习记录 / Learned operation reused:
人工介入、重试或加速 / Intervention, retries or speed-up:
```

## 放进 README

录制完成后，将视频上传为 GitHub 附件，或使用可访问的视频托管链接，在中英文 README 的演示区引用同一个素材。可配一张真实关键帧封面。保留模型、设备、起始条件和实际耗时说明；避免在 Git 历史中放入体积很大的原始视频。

English: begin with one complete reading task, one note-entry task, and one reviewed-learning comparison. Include the task, device/app/build versions, model configuration, actual timing and any human intervention. Label sped-up edits, preserve a full recording when possible, and never present a single run as a general success-rate benchmark.

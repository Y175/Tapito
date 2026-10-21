# Tapito 执行状态 UI

## 本次实现

- 首页：新任务入口、会话摘要和状态；保留会话删除、搜索及原导航。
- 对话：执行卡片使用紫色环形 loading，展示当前阶段与已处理工具数量；工具记录默认折叠，授权卡和完整回执仍可查看。输入框与语音入口保持同一个底部安全区。
- 语音：收紧空闲栏；权限与数据说明可通过信息按钮查看。结束、暂停、恢复复用原语音状态机，未改变音频和后台执行方式。
- 灵动岛：紧凑布局为 loading/状态图标 + 两字阶段；展开布局为当前操作、阶段标签和横向按钮。锁屏卡沿用相同状态映射。
- 交互：语音活动结束指定语音会话，普通活动停止指定 conversationID/runID；旧卡片不会停止后来启动的任务。查看与确认仍跳转原会话授权界面。

## 事件与职责边界

`WorkflowAgentEngine → AssistantEvent.modelStageChanged → AgentSessionController → ContentState → AgentActivityPresentation → SwiftUI / WidgetKit`。

核心仅发布语义事件，不引入 UI 框架：M1/M2 为规划，M3 为核验，M4 为纠错，M5 为整理答复。观察和操作来自实际工具/发送事件。模型流只刷新活跃状态，不把核验重置为规划。

阶段标签是可反复经过的执行环节，不是固定四步进度条。工具计数表示已处理的调用，不等于业务成功次数。没有加入假百分比、计时器推进阶段或额外模型请求。公开状态只含程序定义的标签，不包含用户任务、参数、模型思考、截图或密钥。

等待确认、暂停、异常与终态优先于旧工具状态；过期活动停止 loading，要求查看会话。只有当前会话当前轮次驱动 App 中的任务卡。

## 动画与验证边界

App 内 loading 可持续旋转；WidgetKit 中采用 SF Symbol 的非重复旋转，只由真实阶段/操作/计数变化触发。心跳更新时间不作为动画 key。减少动态效果和低亮度状态下不请求重复动效。

Apple 规定实时活动动画最长两秒，常亮屏低亮度状态不播放动画。当前实现不承诺灵动岛持续旋转或强制自动展开，也不靠频繁更新绕过系统规则：[Apple 动画文档](https://developer.apple.com/documentation/widgetkit/animating-data-updates-in-widgets-and-live-activities)。

验证入口：

```sh
bash ios-app/scripts/test_activity_presentation.sh
swift test --package-path ios-app/TapitoAgentKit --scratch-path .build/AgentCoreTests
```

宿主机状态测试直接编译生产 Foundation 状态/投影源码，不模拟 ActivityKit。Agent 测试验证模型阶段顺序。iPhoneOS `build-for-testing` 检查 App、Widget 和 iOS 测试源码编译；不代表 iOS 测试已执行。

共享组件可在 macOS ImageRenderer 上渲染做静态排版检查；这不验证实际系统灵动岛的高度分配、动画时机或按钮调度，仍需安装后在真机验收。本次未启动模拟器或安装。

## 2026-10-16 真机安装

用户随后授权安装。签名构建与签名完整性校验通过，经局域网成功安装到 175phone（`com.y175.tapito`，0.1.0 / 1）；安装回执保存在 `.build/ui-refresh-install.json`。打包时重新生成并包含内置户外初始化快捷指令。此次安装未执行真实任务，灵动岛动效及交互仍待用户真机验收。

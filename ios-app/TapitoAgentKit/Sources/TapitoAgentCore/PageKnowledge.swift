import Foundation

/// Only stable interface labels may enter procedural memory. Business content stays in the run.
public enum InterfaceVocabulary {
    public static let labels: Set<String> = [
        "搜索", "取消", "返回", "完成", "发送", "确定", "确认", "保存", "编辑", "删除", "添加", "新建",
        "首页", "发现", "消息", "我", "我的", "设置", "更多", "全部", "综合", "用户", "视频", "图片",
        "热搜", "微博热搜", "热搜榜", "关注", "推荐", "评论", "转发", "点赞", "收藏", "分享",
        "微信", "通讯录", "聊天", "朋友圈", "扫一扫", "QQ", "联系人", "动态",
        "备忘录", "文件夹", "所有备忘录", "新建备忘录", "清单", "标题",
        "时钟", "世界时钟", "闹钟", "秒表", "计时器", "重复", "标签", "铃声", "稍后提醒",
        "开始", "暂停", "继续", "停止", "重设", "键盘", "输入消息", "搜索关键词",
        "Search", "Cancel", "Back", "Done", "Send", "Save", "Edit", "Add", "Notes", "Alarms"
    ]
    public static func permits(_ value: String) -> Bool { labels.contains(value) }
}

/// Exact screenshot pixel geometry. A frame's dimensions and coordinates are never silently rescaled.
public struct InterfaceBounds: Codable, Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var centerX: Int { x + width / 2 }
    public var centerY: Int { y + height / 2 }
    public func validate(width screenWidth: Int, height screenHeight: Int) throws {
        guard x >= 0, y >= 0, width > 0, height > 0, width <= screenWidth, height <= screenHeight,
              x <= screenWidth - width, y <= screenHeight - height else {
            throw AssistantError.invalid("页面控件区域超出截图像素空间。")
        }
    }
    public func matches(_ other: Self) -> Bool {
        abs(x - other.x) <= 8 && abs(y - other.y) <= 8 &&
        abs(width - other.width) <= 12 && abs(height - other.height) <= 12
    }
}

/// One OCR anchor, not a native accessibility element or proof of clickability.
public struct InterfaceAnchor: Codable, Equatable, Sendable {
    public let text: String
    public let bounds: InterfaceBounds
    /// Optional 16×16 RGB sample cropped strictly inside this UI label, never its surrounding content.
    public let patch: Data?
    /// Visual controls retain only a SHA-256 digest of their observed region; no raw icon/avatar image.
    public let visualDigest: String?
    public init(text: String, bounds: InterfaceBounds, patch: Data? = nil, visualDigest: String? = nil) {
        self.text = text; self.bounds = bounds; self.patch = patch; self.visualDigest = visualDigest
    }
}

/// A content-free observation: no original image, message, search value, account name or result list.
public struct InterfaceSkeleton: Codable, Equatable, Sendable {
    public let frameID: String
    public let width: Int, height: Int
    public let anchors: [InterfaceAnchor]
    public init(frameID: String, width: Int, height: Int, anchors: [InterfaceAnchor]) {
        self.frameID = frameID; self.width = width; self.height = height; self.anchors = anchors
    }
    public func validate() throws {
        guard !frameID.isEmpty, frameID.count <= 256, (100...10000).contains(width),
              (100...10000).contains(height), (2...80).contains(anchors.count) else {
            throw AssistantError.invalid("页面骨架缺少至少两个稳定 UI 锚点，或尺寸无效。")
        }
        for anchor in anchors {
            guard InterfaceVocabulary.permits(anchor.text) else {
                throw AssistantError.invalid("页面骨架包含未批准的文字；业务内容不能写入页面模板。")
            }
            try anchor.bounds.validate(width: width, height: height)
            if let patch = anchor.patch, patch.count != 768 { throw AssistantError.invalid("控件图像样本尺寸错误。") }
        }
        guard Set(anchors.map { "\($0.text):\($0.bounds.x):\($0.bounds.y)" }).count == anchors.count else {
            throw AssistantError.invalid("页面锚点重复。")
        }
    }
    /// Every stored anchor must remain unique near its original region; extra dynamic content is ignored.
    public func matches(_ current: Self) throws -> Bool {
        try validate(); try current.validate()
        guard width == current.width, height == current.height else { return false }
        return anchors.allSatisfy { expected in
            current.anchors.filter { $0.text == expected.text && expected.bounds.matches($0.bounds) }.count == 1
        }
    }
}

/// Persistable actions contain roles/parameters, never the original text that was entered.
public enum PageControlAction: String, Codable, Sendable { case tap, focusAndType }

/// Host-created evidence ties a control's actual delivered action to a subsequent observed page.
public struct PageTransitionEvidence: Codable, Sendable, Identifiable {
    public let id: UUID
    public let runID: UUID
    public let appBundleID: String
    public let appVersion: String
    public let systemVersion: String
    public let before: InterfaceSkeleton
    public let control: InterfaceAnchor
    public let action: PageControlAction
    public let after: InterfaceSkeleton
    public init(id: UUID = UUID(), runID: UUID, appBundleID: String, appVersion: String,
                systemVersion: String, before: InterfaceSkeleton, control: InterfaceAnchor,
                action: PageControlAction, after: InterfaceSkeleton) {
        self.id = id; self.runID = runID; self.appBundleID = appBundleID; self.appVersion = appVersion
        self.systemVersion = systemVersion; self.before = before; self.control = control
        self.action = action; self.after = after
    }
    public func validate() throws {
        guard !appBundleID.isEmpty, !appVersion.isEmpty, !systemVersion.isEmpty,
              before.frameID != after.frameID, before.width == after.width, before.height == after.height else {
            throw AssistantError.invalid("控件操作缺少独立的前后帧、版本或唯一目标证据。")
        }
        try before.validate(); try after.validate()
        try control.bounds.validate(width: before.width, height: before.height)
        if let digest = control.visualDigest {
            let relativeY = Double(control.bounds.centerY) / Double(before.height)
            guard ((0.07...0.19).contains(relativeY) || (0.85...0.97).contains(relativeY)),
                  control.text == "图标", control.patch == nil, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AssistantError.invalid("图标控件缺少有效的局部图像摘要。")
            }
        } else if before.anchors.filter({ $0 == control }).count != 1 {
            throw AssistantError.invalid("文字控件没有唯一的前置页面锚点。")
        }
    }
}

/// Reviewed page capability. Result describes page transition, never guarantees a send/create business effect.
public struct PageCapability: Codable, Identifiable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let evidence: PageTransitionEvidence
    /// Model-produced descriptions are bounded; coordinates and labels are always copied from host evidence.
    public let pageName: String
    public let function: String
    public let observedResult: String
    public var state: String
    public init(id: UUID = UUID(), revision: UUID = UUID(), evidence: PageTransitionEvidence,
                pageName: String, function: String, observedResult: String, state: String = "candidate") {
        self.id = id; self.revision = revision; self.evidence = evidence; self.pageName = pageName
        self.function = function; self.observedResult = observedResult; self.state = state
    }
    /// These controls need fresh task-specific context; they remain in the knowledge view but cannot bypass M3.
    public var requiresFreshSemanticCheck: Bool {
        if ["发送", "Send", "保存", "Save", "删除", "确定", "确认", "点赞", "转发", "分享"].contains(evidence.control.text) { return true }
        return evidence.action == .focusAndType && !["搜索", "Search", "搜索关键词"].contains(evidence.control.text)
    }
    public func validate() throws {
        try evidence.validate()
        guard ["candidate", "active", "disabled", "stale"].contains(state),
              [pageName, function, observedResult].allSatisfy({ !$0.isEmpty && $0.count <= 160 && !$0.contains("\0") }) else {
            throw AssistantError.invalid("页面能力的名称、功能、结果或状态无效。")
        }
    }
}

/// Parameters bind once at routing time; current-task values never become part of the saved capability.
public struct PageCapabilityCall: Codable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let text: String?
    public init(id: UUID, revision: UUID, text: String? = nil) { self.id = id; self.revision = revision; self.text = text }
}

/// Narrow device port used by deterministic page workflows. The host preserves its existing authorization.
public protocol PageWorkflowDevice: Sendable {
    func pageVersion(app: String) async throws -> String
    func pageObserve(matching reference: InterfaceSkeleton, callID: String) async throws -> InterfaceSkeleton
    func pagePerform(capability: PageCapability, text: String?, observation: InterfaceSkeleton, callID: String) async throws
}

/// A read-only page mismatch carries exact progress so correction never restarts a completed prefix.
public struct PageWorkflowDeviation: Error, LocalizedError, Sendable {
    public let capabilityID: UUID
    public let revision: UUID
    public let completed: Int
    public let inputDelivered: Bool
    public let reason: String
    public var errorDescription: String? { "页面能力偏离：\(reason)；前 \(completed) 段已验证，本段输入已送达=\(inputDelivered)。" }
}

/// Executes a frozen sequence with local page checks and no per-step model roundtrip.
public enum PageWorkflowExecutor {
    public static func run(calls: [PageCapabilityCall], snapshot: [PageCapability], app: String,
                           systemVersion: String, runID: String, device: any PageWorkflowDevice,
                           permit: @Sendable (PageCapability) async throws -> Void) async throws {
        guard (1...16).contains(calls.count) else { throw AssistantError.invalid("页面流程需要 1–16 个已发布能力。") }
        let plan = try calls.map { call -> (PageCapability, String?) in
            guard let item = snapshot.first(where: { $0.id == call.id && $0.revision == call.revision && $0.state == "active" }),
                  item.evidence.appBundleID == app, item.evidence.systemVersion == systemVersion else {
                throw AssistantError.invalid("页面能力不属于本轮启用版本、App 或系统。")
            }
            try item.validate()
            guard !item.requiresFreshSemanticCheck else { throw AssistantError.invalid("此控件需要当次业务内容核实，不能直接进入缓存坐标流程。") }
            switch item.evidence.action {
            case .tap: guard call.text == nil else { throw AssistantError.invalid("点击能力不接收输入文本。") }
            case .focusAndType:
                guard let text = call.text, !text.isEmpty, text.utf8.count <= 8192, !text.contains("\0") else {
                    throw AssistantError.invalid("输入能力缺少有效文本。")
                }
            }
            return (item, call.text)
        }
        let version = try await device.pageVersion(app: app)
        if let pair = plan.first(where: { $0.0.evidence.appVersion != version }) {
            throw PageWorkflowDeviation(capabilityID: pair.0.id, revision: pair.0.revision, completed: 0,
                inputDelivered: false, reason: WorkflowMismatch.version.localizedDescription)
        }
        var observedFrames = Set<String>()
        for (index, pair) in plan.enumerated() {
            var inputDelivered = false
            do {
                try Task.checkCancellation(); try await permit(pair.0)
                let observed = try await device.pageObserve(matching: pair.0.evidence.before, callID: "\(runID).\(index).before")
                guard observedFrames.insert(observed.frameID).inserted else { throw AssistantError.invalid("页面观察复用了旧帧，未发送输入。") }
                guard try pair.0.evidence.before.matches(observed) else { throw WorkflowMismatch.page }
                try Task.checkCancellation(); try await permit(pair.0)
                // Never retry this dispatch. A thrown transport error leaves its outcome unknown.
                try await device.pagePerform(capability: pair.0, text: pair.1, observation: observed, callID: "\(runID).\(index)")
                inputDelivered = true
                try Task.checkCancellation(); try await permit(pair.0)
                let after = try await device.pageObserve(matching: pair.0.evidence.after, callID: "\(runID).\(index).after")
                guard observedFrames.insert(after.frameID).inserted else { throw AssistantError.invalid("输入后的观察复用了旧帧，结果未确认。") }
                guard try pair.0.evidence.after.matches(after) else { throw WorkflowMismatch.page }
            } catch let mismatch as WorkflowMismatch {
                throw PageWorkflowDeviation(capabilityID: pair.0.id, revision: pair.0.revision, completed: index,
                    inputDelivered: inputDelivered, reason: mismatch.localizedDescription)
            }
        }
    }
}

import ActivityKit

/// ActivityKit conformance stays at the system boundary; state/projection are host-testable Foundation types.
extension AgentActivityAttributes: ActivityAttributes {}

import ApplicationServices
import Testing

@testable import dictate

/// One row per branch of the gate's verdict - mirrors the hypothesis table in
/// `thoughts/tasks/fix-clipboard-overwrite-on-paste`.
struct TargetClassifierTests {
    private func classify(
        appPresent: Bool = true,
        focusError: AXError = .success,
        role: String?,
        valueSettable: Bool = false
    ) -> TextInjector.TargetAssessment {
        TextInjector.classify(
            appPresent: appPresent,
            focusError: focusError,
            role: role,
            valueSettable: valueSettable
        )
    }

    @Test
    func noFrontmostApp() {
        #expect(classify(appPresent: false, role: nil) == .noTarget(.noFrontmostApp))
    }

    @Test
    func coldWebTree_noValueError() {
        #expect(classify(focusError: .noValue, role: nil) == .noTarget(.axError(AXError.noValue.rawValue)))
    }

    @Test
    func focusQueryFailure_keepsRawCode() {
        #expect(
            classify(focusError: .cannotComplete, role: nil)
                == .noTarget(.axError(AXError.cannotComplete.rawValue)))
    }

    @Test
    func successWithoutElement_isAxErrorZero() {
        #expect(classify(role: nil) == .noTarget(.axError(0)))
    }

    @Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"])
    func textRole_isTarget(role: String) {
        #expect(classify(role: role) == .target(role: role))
    }

    @Test
    func bareWebArea_isWebContainer() {
        #expect(classify(role: "AXWebArea") == .noTarget(.webContainer))
    }

    @Test
    func bareWebArea_settableStillWebContainer() {
        #expect(classify(role: "AXWebArea", valueSettable: true) == .noTarget(.webContainer))
    }

    @Test
    func nonTextRole_notSettable_isNonText() {
        #expect(classify(role: "AXGroup") == .noTarget(.nonText(role: "AXGroup")))
    }

    @Test
    func nonTextRole_settableValue_isTarget() {
        #expect(classify(role: "AXGroup", valueSettable: true) == .target(role: "AXGroup"))
    }

    @Test
    func unreadableRole_notSettable_isNonText() {
        #expect(classify(role: "unknown") == .noTarget(.nonText(role: "unknown")))
    }

    @Test
    func reasonDescription_isLogFriendly() {
        #expect(TextInjector.NoTargetReason.axError(-25212).description == "axError(-25212)")
        #expect(TextInjector.NoTargetReason.nonText(role: "AXGroup").description == "nonText(AXGroup)")
    }
}

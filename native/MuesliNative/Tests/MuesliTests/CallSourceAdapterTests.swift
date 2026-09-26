import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Call source adapters")
struct CallSourceAdapterTests {
    private let now = Date(timeIntervalSinceReferenceDate: 500)
    private func registry(source: CallSource = .phone) -> CallSourceRegistry {
        CallSourceRegistry(registrations: [CallAdapterRegistration(source: source, bundleID: "test.call",
            supportedVersions: ["fixture-1"])], deviceID: "fixture-device", now: { Date(timeIntervalSinceReferenceDate: 500) })
    }
    private func context(source: CallSource = .phone) -> CallSourceContext {
        CallSourceContext(source: source, bundleID: "test.call", pid: 42, fingerprint: "fixture-call", sourceCallID: "fixture-call")
    }
    private func call(_ handles: [String] = ["+12025550123"], title: String = "Audio call") -> CallAXNode {
        CallAXNode(role: "AXWindow", attributes: ["AXTitle": title], children: [
            CallAXNode(role: "AXButton", attributes: ["AXDescription": "End call"], children: []),
            CallAXNode(role: "AXButton", attributes: ["AXDescription": "Mute microphone"], children: [])
        ] + handles.map { CallAXNode(role: "AXStaticText", attributes: ["AXValue": $0], children: []) })
    }
    private func snapshot(_ roots: [CallAXNode], pid: Int32 = 42, version: String = "fixture-1", capturedAt: Date? = nil) -> CallAXSnapshot {
        CallAXSnapshot(bundleID: "test.call", appVersion: version, pid: pid, capturedAt: capturedAt ?? now, roots: roots)
    }
    @Test func unregisteredAndArbitraryWindowTitlesNeverIdentify() {
        let c = CallSourceContext(source: .phone, bundleID: "test.unregistered", pid: 42, fingerprint: "fixture", sourceCallID: nil)
        let tree = CallAXSnapshot(bundleID: c.bundleID, appVersion: "fixture-1", pid: 42, capturedAt: now, roots: [call()])
        #expect(CallSourceRegistry().parse(snapshot: tree, context: c) == .unavailable("unverifiedSource"))
        #expect(registry().parse(snapshot: snapshot([CallAXNode(role: "AXWindow", attributes: ["AXTitle": "+12025550123"], children: [])]), context: context()) == .unavailable("noActiveCall"))
    }
    @Test(arguments: [CallSource.phone, .facetime, .whatsApp, .signal, .telegram])
    func dedicatedActiveCallCanExposePhone(_ source: CallSource) throws {
        let result = registry(source: source).parse(snapshot: snapshot([call()]), context: context(source: source))
        guard case .observation(let observation) = result else { Issue.record("Expected synthetic active-call observation"); return }
        #expect(observation.source == source)
        #expect(observation.sourceCallID == "fixture-call")
        #expect(observation.sourceDeviceID == "fixture-device")
        #expect(observation.handles == [try #require(CallIdentityNormalizer.phone("+12025550123"))])
        #expect(observation.evidence == .activeCallAX)
        #expect(observation.status == "connected")
    }
    @Test func chatOutsideCallSubtreeCannotBecomeParticipant() throws {
        let chat = CallAXNode(role: "AXWindow", attributes: ["AXTitle": "Chat"], children: [
            CallAXNode(role: "AXStaticText", attributes: ["AXValue": "+12025550999"], children: [])])
        let result = registry().parse(snapshot: snapshot([chat, call()]), context: context())
        guard case .observation(let observation) = result else { Issue.record("Expected observation"); return }
        #expect(observation.handles.map(\.canonicalValue) == ["+12025550123"])
        #expect(registry().parse(snapshot: snapshot([call(title: "Chat")]), context: context()) == .unavailable("noActiveCall"))
    }
    @Test func pidSourceVersionAndFreshnessAreRequired() {
        #expect(registry().parse(snapshot: snapshot([call()], pid: 43), context: context()) == .unavailable("sourceChanged"))
        #expect(registry().parse(snapshot: snapshot([call()]), context: context(source: .signal)) == .unavailable("sourceChanged"))
        #expect(registry().parse(snapshot: snapshot([call()], version: "fixture-2"), context: context()) == .unavailable("unverifiedVersion"))
        #expect(registry().parse(snapshot: snapshot([call()], capturedAt: now.addingTimeInterval(-3)), context: context()) == .unavailable("staleSnapshot"))
        #expect(registry().parse(snapshot: snapshot([call()], capturedAt: now.addingTimeInterval(1)), context: context()) == .unavailable("staleSnapshot"))
    }
    @Test(arguments: ["Private Number", "Unknown", "Fixture Person", "Call +12025550123", "2025550123"])
    func withheldNameOnlyOrProseDoesNotInventHandle(_ value: String) {
        #expect(registry().parse(snapshot: snapshot([call([value])]), context: context()) == .unavailable("handleUnavailable"))
    }
    @Test func groupHandlesAndFaceTimeEmailArePreserved() throws {
        let result = registry(source: .facetime).parse(snapshot: snapshot([call(["caller@example.test", "+12025550123", "caller@example.test"], title: "Video call")]), context: context(source: .facetime))
        guard case .observation(let observation) = result else { Issue.record("Expected group handles"); return }
        #expect(observation.handles.count == 2)
        #expect(Set(observation.handles.map(\.kind)) == [.email, .phone])
        #expect(observation.displayName == nil)
    }
    @Test func usernameIsOnlyReadFromExplicitParticipantField() throws {
        let username = CallAXNode(role: "AXStaticText", attributes: ["AXDescription": "Participant username", "AXValue": "fixture.caller"], children: [])
        var root = call([])
        root = CallAXNode(role: root.role, attributes: root.attributes, children: root.children + [username])
        let result = registry(source: .signal).parse(snapshot: snapshot([root]), context: context(source: .signal))
        guard case .observation(let observation) = result else { Issue.record("Expected explicit service handle"); return }
        #expect(observation.handles.first?.kind == .service)
        #expect(observation.handles.first?.namespace == "signal")
        #expect(observation.handles.first?.canCreateAppleContact == false)
    }
    @Test func multipleCallWindowsAndIncompleteTreesStayUnbound() {
        #expect(registry().parse(snapshot: snapshot([call(), call(["+12025550999"])]), context: context()) == .ambiguous)
        var tree = snapshot([call()])
        tree = CallAXSnapshot(bundleID: tree.bundleID, appVersion: tree.appVersion, pid: tree.pid, capturedAt: tree.capturedAt, roots: tree.roots, isComplete: false)
        #expect(registry().parse(snapshot: tree, context: context()) == .unavailable("readBudgetExceeded"))
    }
    @Test func ringingEndedAndMissingMuteDoNotCountAsConnected() {
        let root = call()
        let ended = CallAXNode(role: root.role, attributes: root.attributes, children: Array(root.children.dropFirst()))
        let ringing = CallAXNode(role: root.role, attributes: root.attributes, children: [root.children[0], root.children[2]])
        #expect(registry().parse(snapshot: snapshot([ended]), context: context()) == .unavailable("noActiveCall"))
        #expect(registry().parse(snapshot: snapshot([ringing]), context: context()) == .unavailable("noActiveCall"))
    }
}

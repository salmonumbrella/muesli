import Foundation
import MuesliCore
import Testing

@Suite("Call identity models")
struct CallIdentityModelTests {
    @Test func internationalFormattingKeepsTheSamePerson() throws {
        let formatted = try #require(CallIdentityNormalizer.phone("+1 (202) 555-0123"))
        let compact = try #require(CallIdentityNormalizer.phone("+12025550123"))
        #expect(formatted.canonicalValue == "+12025550123")
        #expect(formatted.stableKey == "phone|e164|+12025550123|")
        #expect(CallIdentityNormalizer.personID(for: formatted) == CallIdentityNormalizer.personID(for: compact))
        #expect(formatted.canCreateAppleContact)
    }

    @Test(arguments: ["", "Private Number", "Unknown", "+01234567890", "+123", "+1234567890123456",
        "Call +12025550123", "+12025550123; +442079460123", "+1 (202 555-0123", "+1 202) 555-0123",
        "+12025550123\u{202e}", "+12025550123\n", "+12025550123 ext", "+12025550123 ext 123456789"])
    func unrelatedOrMalformedTextIsNotACallerNumber(_ raw: String) {
        #expect(CallIdentityNormalizer.phone(raw) == nil)
    }

    @Test func nationalNumbersKeepTheirExplicitRegionAndStayUnresolved() throws {
        #expect(CallIdentityNormalizer.phone("2025550123") == nil)
        let national = try #require(CallIdentityNormalizer.phone("2025550123", region: "US"))
        #expect(national.stableKey == "phone|national:US|2025550123|")
        #expect(!national.canCreateAppleContact)
        let international = try #require(CallIdentityNormalizer.phone("+12025550123"))
        #expect(CallIdentityNormalizer.personID(for: national) != CallIdentityNormalizer.personID(for: international))
        #expect(CallIdentityNormalizer.phone("2025550123", region: "US|CA") == nil)
    }

    @Test func switchboardExtensionsAreSeparateIdentities() throws {
        let ten = try #require(CallIdentityNormalizer.phone("+12025550123 ext 10"))
        let eleven = try #require(CallIdentityNormalizer.phone("+12025550123 x11"))
        #expect(ten.extensionValue == "10")
        #expect(eleven.extensionValue == "11")
        #expect(CallIdentityNormalizer.personID(for: ten) != CallIdentityNormalizer.personID(for: eleven))
    }

    @Test func emailDoesNotEraseCaseOrPlusAliases() throws {
        let h = try #require(CallIdentityNormalizer.email("Alice+sales@EXAMPLE.test"))
        #expect(h.canonicalValue == "Alice+sales@example.test")
        #expect(h.canCreateAppleContact)
        #expect(CallIdentityNormalizer.email("Alice@example.test")?.stableKey != h.stableKey)
        #expect(CallIdentityNormalizer.email("alice+sales@example.test")?.stableKey != h.stableKey)
    }

    @Test(arguments: ["", "name", "Alice @example.test", "Alice@@example.test", "Alice@example.test\n", "A|B@example.test"])
    func invalidEmailCannotAuthorizeAContact(_ raw: String) {
        #expect(CallIdentityNormalizer.email(raw) == nil)
    }

    @Test func usernamesStayInTheirServiceNamespace() throws {
        let signal = try #require(CallIdentityNormalizer.service("caller.123", namespace: "signal"))
        let telegram = try #require(CallIdentityNormalizer.service("caller.123", namespace: "telegram"))
        #expect(signal.kind == .service)
        #expect(!signal.canCreateAppleContact)
        #expect(CallIdentityNormalizer.personID(for: signal) != CallIdentityNormalizer.personID(for: telegram))
        #expect(CallIdentityNormalizer.service("caller|123", namespace: "signal") == nil)
        #expect(CallIdentityNormalizer.service("caller", namespace: "") == nil)
    }

    @Test func uuidV5MatchesAnIndependentStandardVector() {
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        #expect(CallIdentityNormalizer.uuidV5(namespace: dns, name: "www.example.com") ==
            UUID(uuidString: "2ed6657d-e927-568b-95e1-2665a8aea6a2"))
    }

    @Test func callerIdentityMatchesAnIndependentWireVector() throws {
        let phone = try #require(CallIdentityNormalizer.phone("+12025550123"))
        #expect(CallIdentityNormalizer.personID(for: phone) ==
            UUID(uuidString: "70f42ed0-0023-5347-893f-b6d497feb4f6"))
    }

    @Test func formattingPropertyPreservesCanonicalNumber() throws {
        // A bounded deterministic input sweep catches accidental digit dropping,
        // leading-zero conversion and unstable person IDs without a fuzz dependency.
        for suffix in 0..<256 {
            let digits = String(format: "%04d", suffix)
            let raw = "+1 (202) 555-" + digits
            let phone = try #require(CallIdentityNormalizer.phone(raw))
            #expect(phone.canonicalValue == "+1202555" + digits)
            let again = try #require(CallIdentityNormalizer.phone(phone.canonicalValue))
            #expect(CallIdentityNormalizer.personID(for: phone) == CallIdentityNormalizer.personID(for: again))
        }
    }
}

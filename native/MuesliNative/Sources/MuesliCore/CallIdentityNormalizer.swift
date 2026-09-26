import Foundation
import CryptoKit

public enum CallIdentityNormalizer {
    public static func phone(_ raw: String, region: String? = nil) -> CallHandle? {
        guard safe(raw) else { return nil }
        let pattern = #"^\s*(\+?[0-9][0-9 ()\.\-]*)(?:\s*(?:ext\.?|x)\s*([0-9]{1,8}))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let baseRange = Range(match.range(at: 1), in: raw) else { return nil }
        let base = String(raw[baseRange]).trimmingCharacters(in: .whitespaces)
        let digits = base.filter { $0 >= "0" && $0 <= "9" }
        guard (7...15).contains(digits.count) else { return nil }
        var nesting = 0
        for character in base {
            if character == "(" { nesting += 1; if nesting > 1 { return nil } }
            if character == ")" { nesting -= 1; if nesting < 0 { return nil } }
        }
        guard nesting == 0 else { return nil }
        let ext = Range(match.range(at: 2), in: raw).map { String(raw[$0]) }
        if base.hasPrefix("+") {
            guard digits.first != "0" else { return nil }
            return CallHandle(kind: .phone, rawValue: raw, canonicalValue: "+" + digits,
                namespace: "e164", extensionValue: ext, validation: .internationalSyntax)
        }
        guard let region, region.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil else { return nil }
        return CallHandle(kind: .phone, rawValue: raw, canonicalValue: digits,
            namespace: "national:" + region, extensionValue: ext, validation: .unresolvedNational)
    }
    public static func email(_ raw: String) -> CallHandle? {
        guard safe(raw), raw.range(of: #"^[^@\s|]+@[^@\s|]+\.[^@\s|]+$"#, options: .regularExpression) != nil else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return CallHandle(kind: .email, rawValue: raw,
            canonicalValue: String(parts[0]) + "@" + parts[1].lowercased(),
            namespace: "email", extensionValue: nil, validation: .emailSyntax)
    }
    public static func service(_ raw: String, namespace: String) -> CallHandle? {
        guard safe(raw), safe(namespace), !raw.isEmpty, !namespace.isEmpty,
              !raw.contains("|"), !namespace.contains("|") else { return nil }
        return CallHandle(kind: .service, rawValue: raw, canonicalValue: raw,
            namespace: namespace, extensionValue: nil, validation: .serviceSyntax)
    }
    public static func personID(for handle: CallHandle) -> UUID {
        uuidV5(namespace: UUID(uuidString: "559275fb-2467-5ef4-b428-b6fc3ec91c04")!, name: handle.stableKey)
    }
    public static func uuidV5(namespace: UUID, name: String) -> UUID {
        var tuple = namespace.uuid
        var data = withUnsafeBytes(of: &tuple) { Data($0) }
        data.append(contentsOf: name.utf8)
        var b = Array(Insecure.SHA1.hash(data: data).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],
                           b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    private static func safe(_ text: String) -> Bool {
        !text.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }
    }
}

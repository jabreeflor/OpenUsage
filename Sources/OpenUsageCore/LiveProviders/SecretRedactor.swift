import Foundation

/// Redacts tokens, cookies, emails, JWTs, and other credential material from any error or diagnostic string.
public enum SecretRedactor {
    private static let placeholder = "[REDACTED]"

    private static let regexPatterns: [(regex: NSRegularExpression, template: String)] = {
        let specs: [(String, String)] = [
            // Bearer / Basic authorization headers
            (#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}"#, "$1 [REDACTED]"),
            // JWTs (three base64url segments starting with eyJ)
            (#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]*\b"#, "[REDACTED]"),
            // Provider-prefixed keys and OAuth tokens
            (#"\b(?:sk-ant-[A-Za-z0-9_-]{6,}|sk-[A-Za-z0-9_-]{8,}|ya29\.[A-Za-z0-9._-]{8,}|GOCSPX-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{8,}|gho_[A-Za-z0-9]{8,}|oc_[A-Za-z0-9_-]{8,})\b"#, "[REDACTED]"),
            // Email addresses
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[REDACTED]"),
            // Sensitive URL query parameters
            (#"(?i)([?&](?:access_token|refresh_token|id_token|token|key|api_key|apikey|secret|client_secret|code_verifier|cookie|session|code|state|user|email)=)[^&\s]+"#, "$1[REDACTED]"),
            // Sensitive JSON string fields
            (#"(?i)(\"(?:access_token|refresh_token|id_token|accessToken|refreshToken|token|key|apiKey|api_key|secret|client_secret|clientSecret|code_verifier|cookie|email|account_id|accountId|user_id|userId)\"\s*:\s*\")[^\"]*(\")"#, "$1[REDACTED]$2")
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            return (regex, template)
        }
    }()

    /// Sanitizes `text` by removing known secret values, common credential formats, control characters,
    /// and clamping length so UI subtitles and CLI diagnostics stay concise and secret-free.
    public static func sanitize(
        _ text: String,
        secrets: [String] = [],
        maxLength: Int = 160
    ) -> String {
        var result = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        for secret in secrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { continue }
            result = result.replacingOccurrences(of: trimmed, with: placeholder)
        }

        for entry in regexPatterns {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = entry.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: nsRange,
                withTemplate: entry.template
            )
        }

        let collapsed = result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        if collapsed.count > maxLength {
            return String(collapsed.prefix(maxLength))
        }
        return collapsed
    }
}

/// Inspects only the numeric `exp` timestamp inside a JWT payload in memory without storing or logging any claims.
public enum JWTExpiryInspector {
    public static func expirationDate(fromJWT token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let payloadData = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let expDate = LogTimestampParser.parseJSONTimestamp(object["exp"]) else {
            return nil
        }
        return expDate
    }
}

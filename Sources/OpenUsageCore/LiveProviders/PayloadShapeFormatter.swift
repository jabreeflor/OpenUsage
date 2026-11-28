import CoreFoundation
import Foundation

/// Redacted structural trace of a JSON payload consumed by a live provider parser.
/// Contains only schema-allowlisted key paths, JSON types, schema-allowlisted numeric/enum/ISO-8601 values,
/// boolean/null literals, and `<key>` / `<number>` / `<string len=N>` placeholders — never raw tokens,
/// emails, names, account IDs, dynamic dictionary keys, or URLs.
public struct ProviderPayloadShape: Sendable, Equatable {
    public let source: String
    public let httpStatus: Int?
    public let lines: [String]

    public init(source: String, httpStatus: Int? = nil, lines: [String]) {
        self.source = SecretRedactor.sanitize(source, maxLength: 80)
        self.httpStatus = httpStatus
        self.lines = lines.map { SecretRedactor.sanitize($0, maxLength: 300) }
    }
}

/// Formats JSON payloads into a strictly secret-free structural dump for `--dump-limits-shape`.
/// Uses explicit per-provider tables of known schema paths and public enum values — never syntax heuristics.
public enum JSONShapeFormatter {
    private static let maxFullArrayDumpCount = 8

    private struct SchemaTable: Sendable {
        /// Exact known dictionary keys allowed at each normalized parent path ("" = root).
        let knownKeysByParent: [String: Set<String>]
        /// Top-level keys whose child normalized path maps to `"*"` (used for OpenCode auth.json entries).
        let rootWildcardEntryKeys: Set<String>
        /// Whether unknown top-level keys normalize to `"*"` (true only for OpenCode auth.json / union schema).
        let allowRootWildcardFallback: Bool
        /// Exact normalized paths where a literal string may print, mapped to that path's public enum values.
        let enumValuesByPath: [String: Set<String>]
        /// Exact normalized paths where a strict ISO-8601 timestamp string may print.
        let timestampPaths: Set<String>
        /// Exact normalized paths where a numeric literal may print; all other numbers print as `<number>`.
        let numericPaths: Set<String>

        static func merge(_ tables: [SchemaTable]) -> SchemaTable {
            var knownKeys: [String: Set<String>] = [:]
            var rootWildcardKeys: Set<String> = []
            var allowRootFallback = false
            var enumValues: [String: Set<String>] = [:]
            var timestamps: Set<String> = []
            var numerics: Set<String> = []

            for table in tables {
                for (parent, keys) in table.knownKeysByParent {
                    knownKeys[parent, default: []].formUnion(keys)
                }
                rootWildcardKeys.formUnion(table.rootWildcardEntryKeys)
                if table.allowRootWildcardFallback {
                    allowRootFallback = true
                }
                for (path, values) in table.enumValuesByPath {
                    enumValues[path, default: []].formUnion(values)
                }
                timestamps.formUnion(table.timestampPaths)
                numerics.formUnion(table.numericPaths)
            }

            return SchemaTable(
                knownKeysByParent: knownKeys,
                rootWildcardEntryKeys: rootWildcardKeys,
                allowRootWildcardFallback: allowRootFallback,
                enumValuesByPath: enumValues,
                timestampPaths: timestamps,
                numericPaths: numerics
            )
        }
    }

    private static let claudeLimitEnumValues: Set<String> = [
        "session",
        "five_hour",
        "weekly",
        "seven_day",
        "weekly_all",
        "all_models",
        "opus",
        "sonnet",
        "model",
        "usage",
        "normal",
        "none",
        "info",
        "warning",
        "critical",
        "exceeded"
    ]

    private static let claudeSubscriptionEnumValues: Set<String> = [
        "free",
        "pro",
        "max",
        "max_5x",
        "max_20x",
        "team",
        "enterprise"
    ]

    private static let codexPlanTypeEnumValues: Set<String> = [
        "free",
        "go",
        "plus",
        "pro",
        "prolite",
        "team",
        "business",
        "enterprise",
        "edu"
    ]

    private static let claudeSchema: SchemaTable = {
        let bucketParents = [
            "five_hour",
            "seven_day",
            "seven_day_opus",
            "seven_day_sonnet",
            "seven_day_oauth_apps",
            "seven_day_cowork",
            "iguana_necktie"
        ]
        let bucketKeys: Set<String> = [
            "utilization",
            "used_percent",
            "percent",
            "resets_at",
            "resetsAt",
            "reset_at",
            "resetAt",
            "window_minutes",
            "kind",
            "group",
            "scope",
            "severity",
            "limit",
            "used",
            "remaining"
        ]
        let oauthKeys: Set<String> = [
            "accessToken",
            "access_token",
            "refreshToken",
            "refresh_token",
            "expiresAt",
            "expires_at",
            "scopes",
            "subscriptionType",
            "subscription_type",
            "rateLimitTier",
            "rate_limit_tier"
        ]

        var knownKeys: [String: Set<String>] = [
            "": Set(bucketParents).union(oauthKeys).union([
                "claudeAiOauth",
                "extra_usage",
                "limits",
                "enabled",
                "is_enabled",
                "error"
            ]),
            "claudeAiOauth": oauthKeys,
            "extra_usage": [
                "is_enabled",
                "monthly_limit",
                "used_credits",
                "utilization",
                "currency"
            ],
            "limits[*]": bucketKeys.union(["count"]),
            "error": ["type", "message"]
        ]
        var enumValues: [String: Set<String>] = [
            "limits[*].kind": claudeLimitEnumValues,
            "limits[*].group": claudeLimitEnumValues,
            "limits[*].scope": claudeLimitEnumValues,
            "limits[*].severity": claudeLimitEnumValues,
            "subscriptionType": claudeSubscriptionEnumValues,
            "subscription_type": claudeSubscriptionEnumValues,
            "claudeAiOauth.subscriptionType": claudeSubscriptionEnumValues,
            "claudeAiOauth.subscription_type": claudeSubscriptionEnumValues
        ]
        var timestamps: Set<String> = [
            "limits[*].resets_at",
            "limits[*].resetsAt",
            "limits[*].reset_at",
            "limits[*].resetAt"
        ]
        var numerics: Set<String> = [
            "extra_usage.monthly_limit",
            "extra_usage.used_credits",
            "extra_usage.utilization",
            "limits[*].utilization",
            "limits[*].used_percent",
            "limits[*].percent",
            "limits[*].window_minutes",
            "limits[*].resets_at",
            "limits[*].resetsAt",
            "limits[*].limit",
            "limits[*].used",
            "limits[*].remaining",
            "limits[*].count"
        ]

        for parent in bucketParents {
            knownKeys[parent] = bucketKeys
            for enumKey in ["kind", "group", "scope", "severity"] {
                enumValues["\(parent).\(enumKey)"] = claudeLimitEnumValues
            }
            for tsKey in ["resets_at", "resetsAt", "reset_at", "resetAt"] {
                timestamps.insert("\(parent).\(tsKey)")
            }
            for numKey in ["utilization", "used_percent", "percent", "window_minutes", "resets_at", "resetsAt", "limit", "used", "remaining"] {
                numerics.insert("\(parent).\(numKey)")
            }
        }

        return SchemaTable(
            knownKeysByParent: knownKeys,
            rootWildcardEntryKeys: [],
            allowRootWildcardFallback: false,
            enumValuesByPath: enumValues,
            timestampPaths: timestamps,
            numericPaths: numerics
        )
    }()

    private static let chatGPTSchema: SchemaTable = {
        let windowKeys: Set<String> = [
            "used_percent",
            "window_minutes",
            "resets_at",
            "resets_in_seconds"
        ]
        return SchemaTable(
            knownKeysByParent: [
                "": [
                    "OPENAI_API_KEY",
                    "tokens",
                    "last_refresh",
                    "auth_mode",
                    "plan_type",
                    "limit_id",
                    "limit_name",
                    "primary",
                    "secondary",
                    "credits"
                ],
                "tokens": [
                    "access_token",
                    "refresh_token",
                    "id_token",
                    "account_id"
                ],
                "primary": windowKeys,
                "secondary": windowKeys,
                "credits": [
                    "has_credits",
                    "unlimited",
                    "balance"
                ]
            ],
            rootWildcardEntryKeys: [],
            allowRootWildcardFallback: false,
            enumValuesByPath: [
                "plan_type": codexPlanTypeEnumValues,
                "auth_mode": ["chatgpt", "api_key", "apikey", "oauth"],
                "limit_id": ["codex", "chatgpt", "primary", "secondary"]
            ],
            timestampPaths: [
                "primary.resets_at",
                "secondary.resets_at"
            ],
            numericPaths: [
                "primary.used_percent",
                "primary.window_minutes",
                "primary.resets_at",
                "primary.resets_in_seconds",
                "secondary.used_percent",
                "secondary.window_minutes",
                "secondary.resets_at",
                "secondary.resets_in_seconds",
                "credits.balance"
            ]
        )
    }()

    private static let cursorSchema: SchemaTable = SchemaTable(
        knownKeysByParent: [
            "": [
                "billingCycleStart",
                "billingCycleEnd",
                "billing_cycle_start",
                "billing_cycle_end",
                "planUsage",
                "spendLimitUsage",
                "displayThreshold",
                "enabled",
                "isUnlimited",
                "autoModelSelectedDisplayMessage",
                "namedModelSelectedDisplayMessage",
                "displayMessage",
                "individualUsage",
                "teamUsage"
            ],
            "planUsage": [
                "totalSpend",
                "includedSpend",
                "bonusSpend",
                "remaining",
                "limit",
                "used",
                "totalPercentUsed",
                "autoPercentUsed",
                "apiPercentUsed",
                "bonusTooltip"
            ],
            "spendLimitUsage": [
                "totalSpend",
                "pooledLimit",
                "pooledUsed",
                "pooledRemaining",
                "individualLimit",
                "individualUsed",
                "individualRemaining",
                "limitType"
            ]
        ],
        rootWildcardEntryKeys: [],
        allowRootWildcardFallback: false,
        enumValuesByPath: [
            "spendLimitUsage.limitType": ["user", "team"]
        ],
        timestampPaths: [
            "billingCycleStart",
            "billingCycleEnd",
            "billing_cycle_start",
            "billing_cycle_end"
        ],
        numericPaths: [
            "billingCycleStart",
            "billingCycleEnd",
            "billing_cycle_start",
            "billing_cycle_end",
            "displayThreshold",
            "planUsage.totalSpend",
            "planUsage.includedSpend",
            "planUsage.bonusSpend",
            "planUsage.remaining",
            "planUsage.limit",
            "planUsage.used",
            "planUsage.totalPercentUsed",
            "planUsage.autoPercentUsed",
            "planUsage.apiPercentUsed",
            "spendLimitUsage.totalSpend",
            "spendLimitUsage.pooledLimit",
            "spendLimitUsage.pooledUsed",
            "spendLimitUsage.pooledRemaining",
            "spendLimitUsage.individualLimit",
            "spendLimitUsage.individualUsed",
            "spendLimitUsage.individualRemaining"
        ]
    )

    private static let geminiSchema: SchemaTable = {
        let tierKeys: Set<String> = [
            "id",
            "name",
            "description",
            "isDefault",
            "userDefinedCloudaicompanionProject"
        ]
        let tierIDs: Set<String> = [
            "free-tier",
            "legacy-tier",
            "standard-tier",
            "ultra-tier",
            "enterprise-tier"
        ]
        return SchemaTable(
            knownKeysByParent: [
                "": [
                    "access_token",
                    "refresh_token",
                    "id_token",
                    "scope",
                    "token_type",
                    "expiry_date",
                    "expires_at",
                    "currentTier",
                    "paidTier",
                    "allowedTiers",
                    "ineligibleTiers",
                    "cloudaicompanionProject",
                    "buckets"
                ],
                "currentTier": tierKeys,
                "paidTier": tierKeys,
                "allowedTiers[*]": tierKeys,
                "buckets[*]": [
                    "remainingFraction",
                    "resetTime",
                    "modelId",
                    "tokenType",
                    "remainingAmount"
                ]
            ],
            rootWildcardEntryKeys: [],
            allowRootWildcardFallback: false,
            enumValuesByPath: [
                "token_type": ["bearer", "Bearer"],
                "currentTier.id": tierIDs,
                "paidTier.id": tierIDs,
                "allowedTiers[*].id": tierIDs,
                "buckets[*].tokenType": ["REQUESTS", "TOKENS", "INPUT_TOKENS", "OUTPUT_TOKENS"]
            ],
            timestampPaths: [
                "buckets[*].resetTime"
            ],
            numericPaths: [
                "buckets[*].remainingFraction",
                "buckets[*].remainingAmount"
            ]
        )
    }()

    private static let openCodeSchema: SchemaTable = SchemaTable(
        knownKeysByParent: [
            "": [
                "opencode",
                "opencode-go",
                "opencode-zen",
                "zen",
                "usage"
            ],
            "usage": [
                "rolling",
                "weekly",
                "monthly"
            ],
            "usage.rolling": [
                "status",
                "percent",
                "resetsAt"
            ],
            "usage.weekly": [
                "status",
                "percent",
                "resetsAt"
            ],
            "usage.monthly": [
                "status",
                "percent",
                "resetsAt"
            ],
            "*": [
                "type",
                "key",
                "api_key",
                "apiKey",
                "access",
                "access_token",
                "accessToken",
                "token",
                "refresh",
                "refresh_token",
                "refreshToken",
                "expires",
                "expires_at",
                "expiresAt",
                "expiry_date"
            ]
        ],
        rootWildcardEntryKeys: ["opencode", "opencode-go", "opencode-zen", "zen"],
        allowRootWildcardFallback: true,
        enumValuesByPath: [
            "*.type": ["api", "oauth"],
            "usage.rolling.status": ["ok", "rate-limited"],
            "usage.weekly.status": ["ok", "rate-limited"],
            "usage.monthly.status": ["ok", "rate-limited"]
        ],
        timestampPaths: [
            "usage.rolling.resetsAt",
            "usage.weekly.resetsAt",
            "usage.monthly.resetsAt"
        ],
        numericPaths: [
            "usage.rolling.percent",
            "usage.weekly.percent",
            "usage.monthly.percent"
        ]
    )

    private static let unionSchema: SchemaTable = .merge([
        claudeSchema,
        chatGPTSchema,
        cursorSchema,
        geminiSchema,
        openCodeSchema
    ])

    private static func schema(for provider: ProviderID?) -> SchemaTable {
        guard let provider else { return unionSchema }
        switch provider {
        case .claude: return claudeSchema
        case .chatgpt: return chatGPTSchema
        case .cursor: return cursorSchema
        case .gemini: return geminiSchema
        case .opencode: return openCodeSchema
        }
    }

    public static func format(
        data: Data,
        source: String,
        httpStatus: Int? = nil,
        secrets: [String] = [],
        provider: ProviderID? = nil
    ) -> ProviderPayloadShape {
        ProviderPayloadShape(
            source: source,
            httpStatus: httpStatus,
            lines: formatLines(data: data, secrets: secrets, provider: provider)
        )
    }

    public static func format(
        jsonObject: Any,
        source: String,
        httpStatus: Int? = nil,
        secrets: [String] = [],
        provider: ProviderID? = nil
    ) -> ProviderPayloadShape {
        ProviderPayloadShape(
            source: source,
            httpStatus: httpStatus,
            lines: formatLines(jsonObject: jsonObject, secrets: secrets, provider: provider)
        )
    }

    public static func formatLines(
        data: Data,
        secrets: [String] = [],
        provider: ProviderID? = nil
    ) -> [String] {
        guard !data.isEmpty else {
            return ["(empty)"]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return ["<non-json len=\(data.count)>"]
        }
        return formatLines(jsonObject: object, secrets: secrets, provider: provider)
    }

    public static func formatLines(
        jsonObject: Any,
        secrets: [String] = [],
        provider: ProviderID? = nil
    ) -> [String] {
        var lines: [String] = []
        let table = schema(for: provider)
        appendShape(
            of: jsonObject,
            displayPath: "",
            schemaPath: "",
            schema: table,
            secrets: secrets,
            into: &lines
        )
        return lines.map { SecretRedactor.sanitize($0, secrets: secrets, maxLength: 300) }
    }

    private static func appendShape(
        of value: Any,
        displayPath: String,
        schemaPath: String,
        schema: SchemaTable,
        secrets: [String],
        into lines: inout [String]
    ) {
        let shownPath = displayPath.isEmpty ? "<root>" : displayPath

        if value is NSNull {
            lines.append("\(shownPath): null = null")
            return
        }

        if type(of: value) == Bool.self || CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() {
            let boolVal = (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
            lines.append("\(shownPath): bool = \(boolVal ? "true" : "false")")
            return
        }

        if let str = value as? String {
            if let allowedEnums = schema.enumValuesByPath[schemaPath],
               allowedEnums.contains(str),
               SecretRedactor.sanitize(str, secrets: secrets, maxLength: 64) == str {
                lines.append("\(shownPath): string = \(str)")
                return
            }
            if schema.timestampPaths.contains(schemaPath),
               isStrictISO8601Timestamp(str) {
                let clean = SecretRedactor.sanitize(str, secrets: secrets, maxLength: 64)
                lines.append("\(shownPath): string = \(clean)")
                return
            }
            lines.append("\(shownPath): string = <string len=\(str.count)>")
            return
        }

        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                lines.append("\(shownPath): bool = \(num.boolValue ? "true" : "false")")
            } else if schema.numericPaths.contains(schemaPath) {
                lines.append("\(shownPath): number = \(num.stringValue)")
            } else {
                lines.append("\(shownPath): number = <number>")
            }
            return
        }

        if let dict = value as? [String: Any] {
            if dict.isEmpty {
                lines.append("\(shownPath): object {}")
                return
            }
            let allowedKeys = schema.knownKeysByParent[schemaPath] ?? []
            for key in dict.keys.sorted() {
                let isKnown = allowedKeys.contains(key)
                    && SecretRedactor.sanitize(key, secrets: secrets, maxLength: 80) == key
                let displayKey = isKnown ? key : "<key>"
                let childDisplayPath = displayPath.isEmpty ? displayKey : "\(displayPath).\(displayKey)"

                let childSchemaPath: String
                if schemaPath.isEmpty {
                    if isKnown {
                        childSchemaPath = schema.rootWildcardEntryKeys.contains(key) ? "*" : key
                    } else if schema.allowRootWildcardFallback {
                        childSchemaPath = "*"
                    } else {
                        childSchemaPath = "<key>"
                    }
                } else {
                    childSchemaPath = "\(schemaPath).\(isKnown ? key : "<key>")"
                }

                if let childValue = dict[key] {
                    appendShape(
                        of: childValue,
                        displayPath: childDisplayPath,
                        schemaPath: childSchemaPath,
                        schema: schema,
                        secrets: secrets,
                        into: &lines
                    )
                }
            }
            return
        }

        if let array = value as? [Any] {
            lines.append("\(shownPath): array (len=\(array.count))")
            let countToEmit = array.count <= maxFullArrayDumpCount ? array.count : min(1, array.count)
            let elemSchemaPath = schemaPath.isEmpty ? "[*]" : "\(schemaPath)[*]"
            for index in 0..<countToEmit {
                let elemDisplayPath = displayPath.isEmpty ? "[\(index)]" : "\(displayPath)[\(index)]"
                appendShape(
                    of: array[index],
                    displayPath: elemDisplayPath,
                    schemaPath: elemSchemaPath,
                    schema: schema,
                    secrets: secrets,
                    into: &lines
                )
            }
            return
        }

        lines.append("\(shownPath): unknown")
    }

    /// Returns `true` only when `value` parses completely as an ISO-8601 timestamp (with `T`/`t` date-time separator and no whitespace).
    private static func isStrictISO8601Timestamp(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 19, bytes[10] == 84 || bytes[10] == 116 else { // 'T' or 't'
            return false
        }
        guard !value.contains(where: \.isWhitespace) else {
            return false
        }
        return LogTimestampParser.parseISO8601(value) != nil
    }
}

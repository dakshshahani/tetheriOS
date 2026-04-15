import Foundation

struct Frontmatter: Equatable {
    var date: String?
    var tags: [String]?
    var author: String?
    var title: String?
    var course: String?
    var links: String?
}

struct ParsedContent {
    let frontmatter: Frontmatter?
    let content: String
}

struct FrontmatterDisplay {
    var date: String?
    var tags: String?
    var author: String?
    var title: String?
    var course: String?
    var links: String?

    var isEmpty: Bool {
        date == nil && tags == nil && author == nil && title == nil && course == nil && links == nil
    }
}

private enum FrontmatterValue {
    case string(String)
    case array([String])

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }

        return nil
    }

    var arrayValue: [String]? {
        if case .array(let values) = self {
            return values
        }

        return nil
    }
}

enum VaultMarkdownProcessor {
    static func parseFrontmatter(_ markdown: String) -> ParsedContent {
        if let yamlParsed = parseYAMLFrontmatter(markdown) {
            return yamlParsed
        }

        if let inlineParsed = parseInlineFrontmatter(markdown) {
            return inlineParsed
        }

        return ParsedContent(frontmatter: nil, content: markdown)
    }

    static func formatFrontmatterDisplay(_ frontmatter: Frontmatter?) -> FrontmatterDisplay? {
        guard let frontmatter else {
            return nil
        }

        var display = FrontmatterDisplay()
        display.date = frontmatter.date
        display.author = frontmatter.author
        display.title = frontmatter.title
        display.course = frontmatter.course
        display.links = frontmatter.links

        if let tags = frontmatter.tags, !tags.isEmpty {
            display.tags = tags.joined(separator: ", ")
        }

        return display.isEmpty ? nil : display
    }

    static func buildWikiLookup(files: [MarkdownFileSummary]) -> [String: String] {
        var lookup: [String: String] = [:]

        for file in files {
            let normalizedPath = normalizeForLookup(file.path)
            let stemPath = stripMarkdownExtension(normalizedPath)
            let stemBase = stripMarkdownExtension(basename(normalizedPath))

            if lookup[stemPath] == nil {
                lookup[stemPath] = file.path
            }

            if lookup[stemBase] == nil {
                lookup[stemBase] = file.path
            }
        }

        return lookup
    }

    static func transformObsidianMarkdown(_ content: String, lookup: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"!?\[\[([^\]]+)\]\]"#) else {
            return content
        }

        let fullRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: fullRange)
        var transformed = content

        for match in matches.reversed() {
            guard
                let innerRangeInOriginal = Range(match.range(at: 1), in: content),
                let fullRangeInTransformed = Range(match.range, in: transformed)
            else {
                continue
            }

            let inner = String(content[innerRangeInOriginal])
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let rawTarget = parts.isEmpty ? "" : String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)

            if rawTarget.isEmpty {
                continue
            }

            let rawLabel = parts.count > 1 ? String(parts[1]) : basename(rawTarget)
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTarget = maybeResolveWikiTarget(rawTarget, lookup: lookup)
            let replacement = "[\(label)](\(resolvedTarget))"

            transformed.replaceSubrange(fullRangeInTransformed, with: replacement)
        }

        return transformed
    }

    static func resolveMarkdownLink(currentPath: String, href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return nil
        }

        if hasScheme(trimmed) || trimmed.hasPrefix("//") {
            return nil
        }

        let withoutQuery = trimmed.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let targetPath = withoutQuery.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""

        if targetPath.isEmpty {
            return nil
        }

        let normalizedTarget = normalizeSlashes(targetPath)
        var currentSegments = normalizeSlashes(currentPath)
            .split(separator: "/")
            .map(String.init)

        if !currentSegments.isEmpty {
            currentSegments.removeLast()
        }

        var segments: [String] = normalizedTarget.hasPrefix("/") ? [] : currentSegments

        for part in normalizedTarget.split(separator: "/").map(String.init) {
            if part.isEmpty || part == "." {
                continue
            }

            if part == ".." {
                if !segments.isEmpty {
                    segments.removeLast()
                }
                continue
            }

            segments.append(part)
        }

        if segments.isEmpty {
            return nil
        }

        var resolved = segments.joined(separator: "/")
        if !resolved.lowercased().hasSuffix(".md") {
            resolved += ".md"
        }

        return resolved
    }

    private static func parseYAMLFrontmatter(_ markdown: String) -> ParsedContent? {
        let lines = markdown.components(separatedBy: "\n")
        guard !lines.isEmpty else {
            return nil
        }

        guard lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return nil
        }

        let frontmatterLines = lines[1..<closingIndex]
        let contentLines = lines.dropFirst(closingIndex + 1)
        let frontmatterText = frontmatterLines.joined(separator: "\n")
        let content = contentLines.joined(separator: "\n")

        let properties = parseSimpleProperties(frontmatterText)
        let frontmatter = frontmatterFromProperties(properties)
        return ParsedContent(frontmatter: frontmatter, content: content)
    }

    private static func parseInlineFrontmatter(_ markdown: String) -> ParsedContent? {
        let lines = markdown.components(separatedBy: "\n")
        guard !lines.isEmpty else {
            return nil
        }

        var properties: [String: FrontmatterValue] = [:]
        var propertyEndIndex = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let (key, value) = parseInlineProperty(trimmed) {
                properties[key] = .string(value)
                propertyEndIndex = index + 1
                continue
            }

            if trimmed.isEmpty {
                if !properties.isEmpty {
                    propertyEndIndex = index + 1
                }
                break
            }

            break
        }

        guard !properties.isEmpty else {
            return nil
        }

        let content = lines.dropFirst(propertyEndIndex).joined(separator: "\n")
        return ParsedContent(frontmatter: frontmatterFromProperties(properties), content: content)
    }

    private static func parseSimpleProperties(_ raw: String) -> [String: FrontmatterValue] {
        let lines = raw.components(separatedBy: "\n")
        var properties: [String: FrontmatterValue] = [:]
        var currentArrayKey: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("- "), let currentArrayKey {
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if item.isEmpty {
                    continue
                }

                var array = properties[currentArrayKey]?.arrayValue ?? []
                array.append(stripWrappingQuotes(item))
                properties[currentArrayKey] = .array(array)
                continue
            }

            currentArrayKey = nil

            guard let (key, rawValue) = splitKeyValue(trimmed) else {
                continue
            }

            if rawValue.isEmpty {
                currentArrayKey = key
                if properties[key] == nil {
                    properties[key] = .array([])
                }
                continue
            }

            let value = stripWrappingQuotes(rawValue)

            if value.hasPrefix("[") && value.hasSuffix("]") {
                let inside = String(value.dropFirst().dropLast())
                let items = inside
                    .split(separator: ",")
                    .map { stripWrappingQuotes(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .filter { !$0.isEmpty }
                properties[key] = .array(items)
            } else {
                properties[key] = .string(value)
            }
        }

        return properties
    }

    private static func frontmatterFromProperties(_ properties: [String: FrontmatterValue]) -> Frontmatter? {
        guard !properties.isEmpty else {
            return nil
        }

        var frontmatter = Frontmatter()
        frontmatter.date = properties["date"]?.stringValue
        frontmatter.author = properties["author"]?.stringValue
        frontmatter.title = properties["title"]?.stringValue
        frontmatter.course = properties["course"]?.stringValue
        frontmatter.links = properties["links"]?.stringValue

        if let tagsArray = properties["tags"]?.arrayValue {
            frontmatter.tags = tagsArray
        } else if let tagsString = properties["tags"]?.stringValue {
            let tags = tagsString
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            frontmatter.tags = tags.isEmpty ? [tagsString] : tags
        }

        if frontmatter.date == nil,
           frontmatter.author == nil,
           frontmatter.title == nil,
           frontmatter.course == nil,
           frontmatter.links == nil,
           (frontmatter.tags?.isEmpty ?? true) {
            return nil
        }

        return frontmatter
    }

    private static func parseInlineProperty(_ line: String) -> (String, String)? {
        guard let delimiterRange = line.range(of: "::") else {
            return nil
        }

        let key = String(line[..<delimiterRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = String(line[delimiterRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else {
            return nil
        }

        return (key, value)
    }

    private static func splitKeyValue(_ line: String) -> (String, String)? {
        let delimiterRange: Range<String.Index>?

        if let doubleDelimiter = line.range(of: "::") {
            delimiterRange = doubleDelimiter
        } else {
            delimiterRange = line.range(of: ":")
        }

        guard let delimiterRange else {
            return nil
        }

        let key = String(line[..<delimiterRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = String(line[delimiterRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else {
            return nil
        }

        return (key, value)
    }

    private static func stripWrappingQuotes(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    private static func hasScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":") else {
            return false
        }

        let scheme = value[..<colonIndex]
        guard !scheme.isEmpty else {
            return false
        }

        return scheme.allSatisfy { character in
            character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
        }
    }

    private static func maybeResolveWikiTarget(_ rawTarget: String, lookup: [String: String]) -> String {
        let target = normalizeForLookup(rawTarget)
        let stem = stripMarkdownExtension(target)

        if let direct = lookup[target] {
            return direct
        }

        if let directStem = lookup[stem] {
            return directStem
        }

        return target.hasSuffix(".md") ? target : "\(target).md"
    }

    private static func normalizeSlashes(_ value: String) -> String {
        let replacedBackslashes = value.replacingOccurrences(of: "\\", with: "/")
        guard let repeatedSlashRegex = try? NSRegularExpression(pattern: #"/+"#) else {
            return replacedBackslashes
        }

        let range = NSRange(replacedBackslashes.startIndex..., in: replacedBackslashes)
        return repeatedSlashRegex.stringByReplacingMatches(in: replacedBackslashes, range: range, withTemplate: "/")
    }

    private static func normalizeForLookup(_ value: String) -> String {
        let normalized = normalizeSlashes(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.replacingOccurrences(of: #"^/+"#, with: "", options: .regularExpression)
    }

    private static func stripMarkdownExtension(_ value: String) -> String {
        if value.lowercased().hasSuffix(".md") {
            return String(value.dropLast(3))
        }

        return value
    }

    private static func basename(_ value: String) -> String {
        let cleaned = normalizeSlashes(value).replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let parts = cleaned.split(separator: "/")
        return parts.last.map(String.init) ?? value
    }
}

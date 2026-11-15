import Foundation

extension QMKKeymap {
    /// Plain-English facts for the custom code patterns QMK users write most: tap dances, combos, and custom
    /// keys that type text. Exact, so they're shown as facts; anything else is left to the on-device explainer.
    public static func behaviours(in customCode: String) -> [String] {
        guard customCode.utf8.count <= 64 * 1024 else { return [] }   // regex scans stay small
        let defines = parseDefines(customCode)
        func name(_ token: String) -> String {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = QMKNames.code(t) ?? defines[t].flatMap(QMKNames.code)
                ?? composite(t, layer: { integer($0) }, resolve: { QMKNames.code($0.trimmingCharacters(in: .whitespaces)) })
            return code.map { Keycode.info($0).name } ?? t
        }
        func matches(_ pattern: String, _ text: String) -> [[String]] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
                (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            }
        }
        var facts: [String] = []

        for m in matches(#"\[\s*(\w+)\s*\]\s*=\s*ACTION_TAP_DANCE_DOUBLE\(\s*([^,()]+)\s*,\s*([^,()]+)\s*\)"#, customCode) {
            facts.append("The \(m[0]) key: tap once for \(name(m[1])), tap twice quickly for \(name(m[2])).")
        }

        var comboKeys: [String: [String]] = [:]
        for m in matches(#"(\w+)\s*\[\s*\]\s*=\s*\{([^{}]*?)COMBO_END\s*\}"#, customCode) {
            comboKeys[m[0]] = m[1].split(separator: ",").map { name(String($0)) }.filter { !$0.isEmpty }
        }
        for m in matches(#"COMBO\(\s*(\w+)\s*,\s*([^()]+?|\w+\([^()]*\))\s*\)"#, customCode) {
            guard let keys = comboKeys[m[0]], !keys.isEmpty else { continue }
            facts.append("Pressing \(keys.joined(separator: " and ")) together sends \(name(m[1])).")
        }

        for m in matches(#"case\s+(\w+)\s*:(.*?)(?=case\s+\w+\s*:|default\s*:|$)"#, customCode) {
            let typed = matches(#"SEND_STRING\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#, m[1]).map { $0[0] }
            guard !typed.isEmpty else { continue }
            let text = typed.joined().replacingOccurrences(of: "\\n", with: "⏎").replacingOccurrences(of: "\\\"", with: "\"")
            facts.append("The \(m[0]) key types “\(text)”.")
        }
        return facts
    }
}

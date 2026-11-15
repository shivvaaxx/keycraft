import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Plain-English summary of a keymap's custom code, written by Apple's on-device model. Text only: nothing it
/// returns is acted on. Present only on Macs with Apple Intelligence (macOS 26+).
enum CodeExplainer {
    /// Debug builds only for now: in testing the ~3B on-device model invented behaviour in real keymaps, even when
    /// given the exact facts. Release builds show only the exact facts from `QMKKeymap.behaviours`.
    static var isAvailable: Bool {
        #if DEBUG && canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Why it isn't available, in words, or nil when it is.
    static var unavailableReason: String? {
        #if !DEBUG
        return nil
        #else
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to get an explanation."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready. Try again in a few minutes."
            case .unavailable: return "This Mac doesn't support Apple Intelligence."
            }
        }
        #endif
        return "Explanations need macOS 26 with Apple Intelligence."
        #endif
    }

    /// The model's context is small (about 4,000 tokens), so only the start of long code is sent.
    static let maxCharacters = 6_000

    static func explain(_ code: String, knownFacts: [String]) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: """
                You explain QMK keyboard firmware code to someone who is not a programmer. For each custom behaviour, \
                say which keys it involves, when it triggers, and what it types or changes, using the exact key and \
                colour names from the code. Only describe what the code does; never invent behaviour. If something is \
                unclear, say it's unclear. Use short bullet points and plain words, and don't explain C syntax.

                QMK reference:
                - KC_ESC is Escape, KC_CAPS is Caps Lock, KC_J is the J key, and so on.
                - ACTION_TAP_DANCE_DOUBLE(a, b): tap once for a, tap twice quickly for b.
                - COMBO(keys, kc): pressing all of those keys together sends kc.
                - SEND_STRING("text"): types that text.
                - process_record_user runs on every key press; `case NAME:` handles the custom key NAME.
                - layer_state_set_user runs whenever the active layer changes.
                - rgblight_sethsv...(HSV_RED): sets the keyboard lighting to that colour.
                - LCTL_T(kc), MT(...): tap for kc, hold for a modifier. LT(n, kc): tap for kc, hold for layer n.
                """)
            let options = GenerationOptions(sampling: .greedy)
            do {
                let response = try await session.respond(to: prompt(code, knownFacts: knownFacts), options: options)
                return response.content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                throw ExplainError("This code is too long to explain on this Mac.")
            } catch LanguageModelSession.GenerationError.guardrailViolation, LanguageModelSession.GenerationError.refusal {
                throw ExplainError("The on-device model declined to explain this code.")
            }
        }
        #endif
        throw ExplainError(unavailableReason ?? "Explanations aren't available.")
    }

    private static func prompt(_ code: String, knownFacts: [String]) -> String {
        var p = ""
        if !knownFacts.isEmpty {
            p += "These behaviours are already explained to the user, so don't repeat them:\n"
            p += knownFacts.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            p += "Explain only the other behaviour in this code. If there is none, reply exactly: Nothing else.\n\n"
        } else {
            p += "Explain what this keymap code does.\n\n"
        }
        return p + String(code.prefix(maxCharacters))
    }

    struct ExplainError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

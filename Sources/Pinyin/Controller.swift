import AppKit
import CRime
import Carbon
import InputMethodKit

private let noReplacement = NSRange(location: NSNotFound, length: 0)
private let modifiers: [Int: (code: Int32, flag: NSEvent.ModifierFlags)] = [
    kVK_Shift: (0xFFE1, .shift), kVK_RightShift: (0xFFE2, .shift),
    kVK_Control: (0xFFE3, .control), kVK_RightControl: (0xFFE4, .control),
    kVK_Option: (0xFFE9, .option), kVK_RightOption: (0xFFEA, .option),
    kVK_Command: (0xFFEB, .command), kVK_RightCommand: (0xFFEC, .command),
]
nonisolated(unsafe) private var english = false

func keysym(_ event: NSEvent) -> Int32? {
    switch Int(event.keyCode) {
    case kVK_Return: 0xFF0D
    case kVK_ANSI_KeypadEnter: 0xFF8D
    case kVK_Tab: 0xFF09
    case kVK_Delete: 0xFF08
    case kVK_ForwardDelete: 0xFFFF
    case kVK_Escape: 0xFF1B
    case kVK_Home: 0xFF50
    case kVK_LeftArrow: 0xFF51
    case kVK_UpArrow: 0xFF52
    case kVK_RightArrow: 0xFF53
    case kVK_DownArrow: 0xFF54
    case kVK_PageUp: 0xFF55
    case kVK_PageDown: 0xFF56
    case kVK_End: 0xFF57
    default:
        event.charactersIgnoringModifiers?.unicodeScalars.first
            .flatMap { (0x20 ... 0x7E).contains($0.value) ? Int32($0.value) : nil }
    }
}

func mask(_ flags: NSEvent.ModifierFlags) -> Int32 {
    [(NSEvent.ModifierFlags.shift, 1 << 0), (.capsLock, 1 << 1), (.control, 1 << 2), (.option, 1 << 3), (.command, 1 << 26)]
        .reduce(0) { flags.contains($1.0) ? $0 | $1.1 : $0 }
}

func key(_ event: NSEvent) -> (code: Int32, mask: Int32)? {
    let flags = event.modifierFlags
    switch event.type {
    case .flagsChanged:
        guard let modifier = modifiers[Int(event.keyCode)] else { return nil }
        return (modifier.code, flags.contains(modifier.flag) ? mask(flags) : mask(flags) | 1 << 30)
    case .keyDown where !flags.contains(.command):
        return keysym(event).map { ($0, mask(flags)) }
    default:
        return nil
    }
}

@objc(PinyinController)
final class Controller: IMKInputController {
    private var session: RimeSessionId = 0
    private var marked = ""

    deinit {
        _ = rime.destroy_session(session)
    }

    override func recognizedEvents(_: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput, let key = key(event) else { return false }
        if !rime.find_session(session) {
            session = rime.create_session()
            rime.set_option(session, "_horizontal", true)
        }
        if rime.get_option(session, "ascii_mode") != english {
            rime.set_option(session, "ascii_mode", english)
        }
        let handled = rime.process_key(session, key.code, key.mask)
        update(client)
        if rime.get_option(session, "ascii_mode") != english {
            english.toggle()
            let caret = caret(client)
            MainActor.assumeIsolated { Candidates.shared.flash(english ? "英" : "中", at: caret) }
        }
        return handled
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput,
              let input = rime.get_input(session), input.pointee != 0
        else { return }
        let text = String(cString: input)
        rime.clear_composition(session)
        insert(text, into: client)
        hidePalettes()
    }

    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        hidePalettes()
        super.deactivateServer(sender)
    }

    override func hidePalettes() {
        MainActor.assumeIsolated { Candidates.shared.hide() }
        super.hidePalettes()
    }

    private func insert(_ text: String, into client: IMKTextInput) {
        client.insertText(text, replacementRange: noReplacement)
        marked = ""
    }

    private func caret(_ client: IMKTextInput) -> NSRect {
        var caret = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        return caret
    }

    private func update(_ client: IMKTextInput) {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        if rime.get_commit(session, &commit) {
            if let text = commit.text {
                insert(String(cString: text), into: client)
            }
            _ = rime.free_commit(&commit)
        }

        var context = RimeContext_stdbool()
        context.data_size = Int32(MemoryLayout<RimeContext_stdbool>.size - MemoryLayout<Int32>.size)
        guard rime.get_context(session, &context) else { return hidePalettes() }
        defer { _ = rime.free_context(&context) }

        let preedit = context.composition.preedit.map { String(cString: $0) } ?? ""
        if !(preedit.isEmpty && marked.isEmpty) {
            let caret = String(decoding: preedit.utf8.prefix(Int(context.composition.cursor_pos)), as: UTF8.self).utf16.count
            client.setMarkedText(preedit, selectionRange: NSRange(location: caret, length: 0), replacementRange: noReplacement)
            marked = preedit
        }

        let menu = context.menu
        let candidates = (0 ..< Int(menu.num_candidates)).map { index in
            let candidate = menu.candidates[index]
            return (text: candidate.text.map { String(cString: $0) } ?? "",
                    comment: candidate.comment.map { String(cString: $0) } ?? "")
        }
        guard !candidates.isEmpty else { return hidePalettes() }
        let caret = caret(client)
        let highlighted = Int(menu.highlighted_candidate_index)
        let first = menu.page_no == 0, last = menu.is_last_page
        MainActor.assumeIsolated {
            Candidates.shared.show(candidates, highlighted: highlighted, first: first, last: last, at: caret)
        }
    }
}

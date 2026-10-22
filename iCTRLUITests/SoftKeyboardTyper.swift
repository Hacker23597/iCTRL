import XCTest

/// Types by tapping the on-screen keyboard instead of sending key events.
///
/// XCTest's text input goes through a virtual hardware keyboard that
/// testmanagerd attaches for the length of each type call. Attaching it makes
/// UIKit minimize the software keyboard, and some custom input bars (the
/// Xianyu chat field, for one) take the keyboard leaving as "editing ended":
/// they resign and never insert the text. Taps on the keyboard's own keys go
/// through the keyboard's normal insertion path instead, the same as a finger.
///
/// Han text is entered the way a person would: its pinyin on the letter keys,
/// then the candidate that matches. Works with keyboards whose keys are in the
/// accessibility tree (the system keyboards and Gboard).
///
/// Never presses Return, Send, Go or the like while typing: in a chat that
/// sends the message. Every tap goes through `press`, which refuses them; the
/// two deliberate exceptions (committing an open pinyin composition, and
/// submit) are called out where they happen.
final class SoftKeyboardTyper {
    struct Key {
        let label: String
        let identifier: String
        let frame: CGRect
        var isCandidate = false
        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    struct Failure: Error {
        let message: String
        let typed: String
    }

    private let bundleId: String
    /// Taps the points in order, as one gesture record.
    private let tapAll: ([CGPoint]) -> Void
    private let log: (String) -> Void
    /// Wait after a tap before reading the keyboard again.
    private static let tapGap: useconds_t = 120_000

    /// What the caller should know about how the text went in (case lost to
    /// an input method, say).
    private(set) var notes: [String] = []

    init(bundleId: String, tapAll: @escaping ([CGPoint]) -> Void, log: @escaping (String) -> Void) {
        self.bundleId = bundleId
        self.tapAll = tapAll
        self.log = log
    }

    // MARK: reading the keyboard

    /// The keys on screen, in screen coordinates.
    ///
    /// A keyboard extension (Gboard) reports frames relative to its own
    /// window. Its root shows up as a child the size of its host, at (0, 0)
    /// while the host sits further down: from there on the host's origin is
    /// added.
    func readKeys() -> [Key] {
        let t0 = CACurrentMediaTime()
        guard let root = ForegroundApp.boundedSnapshot(forBundleID: bundleId, maxDepth: 80, maxChildren: 200)
                as? NSObject else { return [] }
        var keys: [Key] = []
        // (node, offset to screen coordinates, parent's frame as reported)
        var stack: [(NSObject, CGPoint, CGRect)] = [(root, .zero, .null)]
        let keyType = XCUIElement.ElementType.key.rawValue
        while let (node, offset, parentRaw) = stack.popLast() {
            let raw = (node.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
            var off = offset
            if !parentRaw.isNull, raw.origin == .zero, parentRaw.origin != .zero,
               abs(raw.width - parentRaw.width) < 1, abs(raw.height - parentRaw.height) < 1 {
                off = CGPoint(x: offset.x + parentRaw.minX, y: offset.y + parentRaw.minY)
            }
            if (node.value(forKey: "elementType") as? NSNumber)?.uintValue == keyType, raw.width > 0, raw.height > 0 {
                keys.append(Key(label: node.value(forKey: "label") as? String ?? "",
                                identifier: node.value(forKey: "identifier") as? String ?? "",
                                frame: raw.offsetBy(dx: off.x, dy: off.y)))
            }
            for c in (node.value(forKey: "children") as? [NSObject]) ?? [] { stack.append((c, off, raw)) }
        }
        log(String(format: "⌨️ read %d keys (%.0fms)", keys.count, (CACurrentMediaTime() - t0) * 1000))
        return Self.markCandidates(keys)
    }

    /// Candidates are the labeled keys above the key rows: the input
    /// method's candidate bar. Position, not script, tells them apart:
    /// function keys carry Han labels too (Gboard's 空格, 删除, 返回), but they
    /// sit in the rows.
    private static func markCandidates(_ keys: [Key]) -> [Key] {
        // The rows: Gboard names its row keys key_pos_*; a system keyboard's
        // rows are one-character ASCII keys (letters, or digits and
        // punctuation on the other planes).
        let rowTop = keys.filter { $0.identifier.hasPrefix("key_pos_") || ($0.label.count == 1 && $0.label.first!.isASCII) }
            .map(\.frame.minY).min() ?? .greatestFiniteMagnitude
        return keys.map { k in
            var k = k
            k.isCandidate = !k.label.isEmpty && k.frame.maxY <= rowTop + 1
                && !["search_logo", "more_candidates"].contains(k.identifier)
            return k
        }
    }

    /// A keyboard is up: enough keys with a one-letter label.
    static func isKeyboard(_ keys: [Key]) -> Bool {
        keys.filter { $0.label.count == 1 && $0.label.first!.isLetter }.count >= 10
    }

    // MARK: finding keys

    private static func matches(_ k: Key, labels: [String], ids: [String]) -> Bool {
        let l = k.label.lowercased(), i = k.identifier.lowercased()
        return labels.contains { l == $0 } || ids.contains { i.contains($0) }
    }

    /// Keys that act on the field: Return and its stand-ins (Send, Go,
    /// Search, Done…). Gboard's is `key_pos_action` or, in a web field,
    /// `key_pos_websearch_action`, labeled 回车键, 返回, 确定 and the like.
    static func isSubmitKey(_ k: Key) -> Bool {
        let i = k.identifier.lowercased()
        if i.contains("action") || i.contains("return") || i.contains("enter") { return true }
        return ["return", "send", "search", "go", "done", "next", "join", "route", "continue", "emergency call",
                "发送", "發送", "傳送", "搜索", "搜尋", "前往", "完成", "换行", "換行", "下一项", "下一項",
                "回车键", "回車鍵", "返回", "确定", "確定", "确认", "確認", "加入", "继续", "繼續"]
            .contains(k.label.lowercased())
    }

    private func letterKey(_ c: Character, in keys: [Key]) -> Key? {
        let s = String(c).lowercased()
        return keys.first { $0.label == s && !$0.isCandidate }
            ?? keys.first { $0.label.lowercased() == s && !$0.isCandidate }
    }

    private func spaceKey(_ keys: [Key]) -> Key? {
        keys.first { Self.matches($0, labels: ["space", "空格", "空格鍵", "空格键", "空白鍵", "空白键"], ids: ["space"]) }
    }

    private func shiftKey(_ keys: [Key]) -> Key? {
        keys.first { $0.label.lowercased().contains("shift") || Self.matches($0, labels: ["上档键", "上檔鍵"], ids: []) }
    }

    private func deleteKey(_ keys: [Key]) -> Key? {
        keys.first { Self.matches($0, labels: ["delete", "删除", "刪除"], ids: ["key_pos_del", "delete"]) }
    }

    /// Return / Send / Search / Go: only for submit.
    func returnKey(_ keys: [Key]) -> Key? {
        keys.first(where: Self.isSubmitKey)
    }

    private func symbolsKey(_ keys: [Key]) -> Key? {
        keys.first { Self.matches($0, labels: ["123", "more, numbers", "numbers", "更多，数字", "更多，數字", "数字", "數字"], ids: []) }
    }

    private func lettersKey(_ keys: [Key]) -> Key? {
        keys.first { Self.matches($0, labels: ["abc", "more, letters", "letters", "更多，字母", "字母"], ids: []) }
    }

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
            || (0x20000...0x2FA1F).contains($0.value) }
    }

    /// A pinyin composition is open. Candidates alone don't show it: after a
    /// pick, Gboard keeps a bar of predictions up with nothing composed.
    /// Gboard's Shift turns into the syllable separator ('词) while composing;
    /// the system pinyin keyboard's return key reads 确认. A keyboard that
    /// shows neither is judged by its candidates.
    static func isComposing(_ keys: [Key]) -> Bool {
        if let shift = keys.first(where: { $0.identifier == "key_pos_shift" }) {
            return shift.label.contains("词") || shift.label.contains("詞")
        }
        if keys.contains(where: { matches($0, labels: ["确认", "確認", "confirm"], ids: []) }) { return true }
        return keys.contains(where: \.isCandidate)
    }

    // MARK: pressing

    /// Tap these keys in order. Refuses any that would act on the field (see
    /// isSubmitKey): typing must never send.
    private func press(_ keys: [Key], typed: String) throws {
        if let bad = keys.first(where: Self.isSubmitKey) {
            throw Failure(message: "Stopped before pressing \"\(bad.label)\": it would submit the field (send, search, go).",
                          typed: typed)
        }
        guard !keys.isEmpty else { return }
        tapAll(keys.map(\.center))
        usleep(Self.tapGap)
    }

    /// Read until the keyboard stops changing: the candidate bar fills in as
    /// the letters arrive, and a tap on a bar still being redrawn is lost.
    private func settledKeys() -> [Key] {
        var keys = readKeys()
        for _ in 0..<4 {
            usleep(60_000)
            let next = readKeys()
            if Self.layout(next) == Self.layout(keys) { return next }
            keys = next
        }
        return keys
    }

    /// The whole keyboard as text: what changes when a pick takes.
    private static func layout(_ keys: [Key]) -> [String] {
        keys.map { "\($0.label)@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
    }

    /// Tap a candidate and check the keyboard changed. No second tap when it
    /// didn't: if the first one did take after all, a second would pick
    /// whatever now sits in that spot.
    private func choose(_ k: Key, from keys: [Key], typed: String) throws -> [Key] {
        try press([k], typed: typed)
        let after = settledKeys()
        guard Self.layout(after) != Self.layout(keys) else {
            throw Failure(message: "Tapping the candidate \"\(k.label)\" changed nothing on the keyboard; "
                          + "the keyboard may still be composing.", typed: typed)
        }
        return after
    }

    // MARK: typing

    /// Type `text`, returning what was typed. Throws with the part that made
    /// it in when a character can't be produced.
    func type(_ text: String) throws -> String {
        var keys = readKeys()
        guard Self.isKeyboard(keys) else {
            throw Failure(message: "No on-screen keyboard with readable keys.", typed: "")
        }
        notes = []
        var typed = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if Self.isHan(c) {
                var j = i
                while j < text.endIndex, Self.isHan(text[j]) { j = text.index(after: j) }
                try typeHan(String(text[i..<j]), keys: &keys, typed: &typed)
                i = j
                continue
            }
            if c.isASCII, c.isLetter {
                var j = i
                while j < text.endIndex, text[j].isASCII, text[j].isLetter { j = text.index(after: j) }
                try typeWord(String(text[i..<j]), keys: &keys, typed: &typed)
                i = j
                continue
            }
            if c == " ", let s = spaceKey(keys) {
                try press([s], typed: typed)
            } else if let k = keys.first(where: { $0.label == String(c) && !$0.isCandidate }) {
                try press([k], typed: typed)
            } else {
                try typeFromSymbols(c, keys: &keys, typed: typed)
            }
            typed.append(c)
            i = text.index(after: i)
        }
        return typed
    }

    /// A run of ASCII letters. The first letter shows whether the keyboard
    /// inserts directly or composes (a pinyin keyboard): composing, Shift
    /// becomes the syllable separator, so the word is typed in lower case and
    /// taken from the candidates, or committed as typed.
    private func typeWord(_ word: String, keys: inout [Key], typed: inout String) throws {
        var letters: [Key] = []
        for c in word {
            guard let k = letterKey(c, in: keys) else {
                throw Failure(message: "No key for \"\(c)\" on the keyboard.", typed: typed)
            }
            letters.append(k)
        }
        try press([letters[0]], typed: typed)
        keys = settledKeys()
        if !Self.isComposing(keys) {
            if word.first!.isUppercase, let shift = shiftKey(keys), let del = deleteKey(keys) {
                // Redo the first letter shifted.
                try press([del, shift, letters[0]], typed: typed)
            }
            // Shift is one-shot: lower case goes in batches, each capital
            // with its own Shift.
            var batch: [Key] = []
            for (n, c) in word.dropFirst().enumerated() {
                if c.isUppercase, let shift = shiftKey(keys) {
                    try press(batch, typed: typed); batch = []
                    try press([shift, letters[n + 1]], typed: typed)
                } else {
                    batch.append(letters[n + 1])
                }
            }
            try press(batch, typed: typed)
            typed += word
            return
        }
        try press(Array(letters.dropFirst()), typed: typed)
        keys = settledKeys()
        let candidates = keys.filter(\.isCandidate)
        if let pick = candidates.first(where: { $0.label == word })
            ?? candidates.first(where: { $0.label.lowercased() == word.lowercased() }) {
            keys = try choose(pick, from: keys, typed: typed)
            if pick.label != word { notes.append("\"\(word)\" went in as \"\(pick.label)\" (the input method's spelling).") }
            typed += pick.label
        } else {
            try commit(&keys, typed: typed)
            if word != word.lowercased() { notes.append("\"\(word)\" went in as \"\(word.lowercased())\": the pinyin keyboard has no capitals here.") }
            typed += word.lowercased()
        }
    }

    /// Commit the open composition as the raw letters typed.
    ///
    /// The one place a Return-like key is pressed while typing: with a
    /// composition open, the return key commits it instead of acting on the
    /// field. It must read 确认 (system pinyin), or be Gboard's action key
    /// while Shift shows the syllable separator ('词), Gboard's sign that a
    /// composition is open. Anything else is refused: it could be Send.
    private func commit(_ keys: inout [Key], typed: String) throws {
        keys = readKeys()
        let confirm = keys.first { Self.matches($0, labels: ["确认", "確認", "confirm"], ids: []) }
        let separator = keys.contains { $0.identifier == "key_pos_shift" && ($0.label.contains("词") || $0.label.contains("詞")) }
        let gboardAction = separator ? keys.first { $0.identifier == "key_pos_action" } : nil
        guard Self.isComposing(keys), let k = confirm ?? gboardAction else {
            throw Failure(message: "Letters are waiting in the input method's composition and there is no key known "
                          + "to commit them without sending.", typed: typed)
        }
        tapAll([k.center])   // deliberate: see above
        usleep(Self.tapGap)
        keys = readKeys()
    }

    private func typeFromSymbols(_ c: Character, keys: inout [Key], typed: String) throws {
        guard let sym = symbolsKey(keys) else {
            throw Failure(message: "No key for \"\(c)\" and no key to switch to numbers and symbols.", typed: typed)
        }
        try press([sym], typed: typed)
        // The plane takes a moment to swap: wait until the letters are gone.
        for _ in 0..<5 {
            keys = readKeys()
            if letterKey("a", in: keys) == nil { break }
            usleep(150_000)
        }
        guard let k = keys.first(where: { $0.label == String(c) && !$0.isCandidate }) else {
            if let back = lettersKey(keys) { try press([back], typed: typed); keys = readKeys() }
            throw Failure(message: "No key for \"\(c)\" on the letter or number keyboard.", typed: typed)
        }
        try press([k], typed: typed)
        keys = readKeys()
        // Back to letters, unless the keyboard went back by itself.
        if letterKey("a", in: keys) == nil {
            guard let back = lettersKey(keys) else {
                throw Failure(message: "Typed \"\(c)\" but found no key to return to the letters.", typed: typed + String(c))
            }
            try press([back], typed: typed + String(c))
            for _ in 0..<5 {
                keys = readKeys()
                if letterKey("a", in: keys) != nil { break }
                usleep(150_000)
            }
        }
    }

    /// Han text through pinyin: type the run's pinyin, then take the longest
    /// candidate that begins what is left, until the run is in. The input
    /// method keeps composing what is left after each pick. A character the
    /// bar doesn't offer is looked for in the expanded candidate list: the
    /// transform gives one reading per character (便宜 comes out "bianyi",
    /// not "pianyi"), so the input method may split the pinyin differently.
    ///
    /// No deletes here: whether a delete removes composition or committed
    /// text can't be told reliably from outside, so a run that can't be
    /// finished is left composing and reported.
    private func typeHan(_ run: String, keys: inout [Key], typed: inout String) throws {
        guard let pinyin = Self.pinyin(run), !pinyin.isEmpty else {
            throw Failure(message: "Could not work out the pinyin for \"\(run)\".", typed: typed)
        }
        try pressPinyin(pinyin, of: run, keys: &keys, typed: typed)
        var left = run
        while !left.isEmpty {
            var best = Self.longestPrefix(of: left, in: keys.filter(\.isCandidate))
            if best == nil, let more = keys.first(where: { $0.identifier == "more_candidates" }) {
                try press([more], typed: typed)
                keys = settledKeys()
                // The expanded list covers the rows: any non-row key counts.
                best = Self.longestPrefix(of: left, in: keys.filter { !$0.identifier.hasPrefix("key_pos_") && !$0.label.isEmpty })
            }
            let expanded = keys.contains { $0.label == "收起候选项视图" }
            guard let pick = best else {
                throw Failure(message: "The input method offered no candidate for \"\(left)\" (pinyin of \"\(run)\": \"\(pinyin)\"). "
                              + "Its pinyin is still in the keyboard's composition, not in the field.", typed: typed)
            }
            keys = try choose(pick, from: keys, typed: typed)
            typed += pick.label
            left.removeFirst(pick.label.count)
            // The expanded list stays open after a pick: fold it so the next
            // round reads the bar and the rows again.
            if expanded, let fold = keys.first(where: { $0.label == "收起候选项视图" }) {
                try press([fold], typed: typed)
                keys = settledKeys()
            }
        }
    }

    private static func longestPrefix(of text: String, in keys: [Key]) -> Key? {
        keys.filter { !$0.label.isEmpty && text.hasPrefix($0.label) }.max { $0.label.count < $1.label.count }
    }

    /// Type pinyin letters and wait for the candidates. None means the
    /// letters went in as they are: not a pinyin keyboard, so take them out.
    private func pressPinyin(_ pinyin: String, of text: String, keys: inout [Key], typed: String) throws {
        var letters: [Key] = []
        for p in pinyin {
            guard let k = letterKey(p, in: keys) else {
                throw Failure(message: "No key for \"\(p)\" (pinyin of \"\(text)\") on the keyboard.", typed: typed)
            }
            letters.append(k)
        }
        try press(letters, typed: typed)
        keys = settledKeys()
        if !Self.isComposing(keys) {
            if let del = deleteKey(keys) { try press(Array(repeating: del, count: pinyin.count), typed: typed) }
            throw Failure(message: "The keyboard is not in a Chinese (pinyin) input mode, so \"\(text)\" can't be typed on it. "
                          + "Switch the keyboard to Chinese pinyin and try again.", typed: typed)
        }
    }

    /// Toneless pinyin letters for Han text, "ü" as "v" as pinyin keyboards
    /// expect.
    static func pinyin(_ s: String) -> String? {
        let m = NSMutableString(string: s)
        guard CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false) else { return nil }
        // Decomposed, "ǚ" is u + diaeresis + tone mark: the diaeresis makes
        // it "v", every other mark is a tone and goes.
        var out = ""
        let scalars = Array((m as String).lowercased().decomposedStringWithCanonicalMapping.unicodeScalars)
        for (n, u) in scalars.enumerated() {
            if u == "u", n + 1 < scalars.count, scalars[n + 1].value == 0x308 { out.append("v"); continue }
            if u.isASCII, CharacterSet.letters.contains(u) { out.unicodeScalars.append(u) }
        }
        return out
    }
}

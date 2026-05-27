#if os(iOS)
import Foundation

enum KeyboardPage {
    case letters
    case numbers
    case symbols
}

enum ShiftState {
    case lowercase
    case uppercaseOnce
    case capsLock
}

/// One renderable key. Visuals are decided by `KeyView` from the case.
enum Key: Equatable {
    case letter(String)        // "a"/"A" — case handled at render time
    case digit(String)         // "1", "0"
    case symbol(String)        // ".", ":", "@", etc.
    case shift
    case backspace
    case page(KeyboardPage)    // "123" / "ABC" / "#+="
    case globe
    case space
    case `return`
    case mic                   // Yaprflow's dictation trigger
}

/// Static layout definitions for the three pages. The numeric row weights
/// (`width`) let the layout engine size keys proportionally inside a row.
struct KeyRowSpec {
    let keys: [(Key, CGFloat)] // (key, relative width — sums per row decide spacing)
}

enum KeyboardLayout {
    static func rows(for page: KeyboardPage) -> [KeyRowSpec] {
        switch page {
        case .letters:
            return [
                row("qwertyuiop".map(String.init).map { (Key.letter($0), 1.0) }),
                row("asdfghjkl".map(String.init).map { (Key.letter($0), 1.0) }, leadingInset: true),
                .init(keys: [
                    (.shift, 1.5),
                ] + "zxcvbnm".map { (Key.letter(String($0)), 1.0) } + [
                    (.backspace, 1.5),
                ]),
                .init(keys: [
                    (.page(.numbers), 1.5),
                    (.globe, 1.0),
                    (.space, 6.0),
                    (.return, 1.5),
                ]),
            ]
        case .numbers:
            return [
                row("1234567890".map(String.init).map { (Key.digit($0), 1.0) }),
                row(["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { (Key.symbol($0), 1.0) }),
                .init(keys: [
                    (.page(.symbols), 1.5),
                ] + [".", ",", "?", "!", "'"].map { (Key.symbol($0), 1.0) } + [
                    (.backspace, 1.5),
                ]),
                .init(keys: [
                    (.page(.letters), 1.5),
                    (.globe, 1.0),
                    (.space, 6.0),
                    (.return, 1.5),
                ]),
            ]
        case .symbols:
            return [
                row(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { (Key.symbol($0), 1.0) }),
                row(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map { (Key.symbol($0), 1.0) }),
                .init(keys: [
                    (.page(.numbers), 1.5),
                ] + [".", ",", "?", "!", "'"].map { (Key.symbol($0), 1.0) } + [
                    (.backspace, 1.5),
                ]),
                .init(keys: [
                    (.page(.letters), 1.5),
                    (.globe, 1.0),
                    (.space, 6.0),
                    (.return, 1.5),
                ]),
            ]
        }
    }

    private static func row(_ keys: [(Key, CGFloat)], leadingInset: Bool = false) -> KeyRowSpec {
        // Inset row (9 keys) sums to 9 but the spec just records widths; the
        // renderer compares total against 10 and pads each side.
        _ = leadingInset
        return KeyRowSpec(keys: keys)
    }
}
#endif

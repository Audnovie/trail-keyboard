// iOS's text proxy as the engine's TextDocument (see Shared/Engine/ProxyTarget.swift for how
// the word in progress is kept in the app's text field).

import UIKit
import TrailEngine

final class ProxyDocument: TextDocument {
    private let proxy: () -> UITextDocumentProxy

    init(_ proxy: @escaping () -> UITextDocumentProxy) {
        self.proxy = proxy
    }

    var textBeforeCursor: String? { proxy().documentContextBeforeInput }
    var textAfterCursor: String? { proxy().documentContextAfterInput }
    func insertText(_ text: String) { proxy().insertText(text) }
    func deleteBackward() { proxy().deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) { proxy().adjustTextPosition(byCharacterOffset: offset) }
}

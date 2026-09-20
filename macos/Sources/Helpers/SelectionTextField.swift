import SwiftUI

/// Bridges the search model's string range to SwiftUI's text selection binding.
struct SelectionTextField: View {
    private let titleKey: LocalizedStringKey
    @Binding private var text: String
    @Binding private var textSelection: Range<String.Index>?

    init(
        _ titleKey: LocalizedStringKey,
        text: Binding<String>,
        selection: Binding<Range<String.Index>?>
    ) {
        self.titleKey = titleKey
        self._text = text
        self._textSelection = selection
    }

    var body: some View {
        TextField(
            titleKey,
            text: _text,
            selection: Binding(
                get: {
                    if let textSelection {
                        TextSelection(range: textSelection)
                    } else {
                        nil
                    }
                },
                set: { selection in
                    if let selection,
                       case .selection(let range) = selection.indices {
                        self.textSelection = range
                    } else {
                        self.textSelection = nil
                    }
                }
            )
        )
    }
}

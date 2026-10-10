import AppKit
import SwiftUI

/// A row of user-definable macro buttons above the message field. Clicking
/// one hands its message to `onInsert`; right-clicking one opens an editor
/// for its title and message.
struct MacroBar: View {
    @EnvironmentObject private var settings: AppSettings

    let isDisabled: Bool
    let onInsert: (String) -> Void

    // Which macro slot is open in the editor sheet, if any.
    private struct EditingSlot: Identifiable {
        let id: Int
    }

    @State private var editingSlot: EditingSlot?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(settings.macros.indices, id: \.self) { index in
                Button {
                    onInsert(settings.macros[index].message)
                } label: {
                    Text(settings.macros[index].title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled)
                .help(settings.macros[index].message)
                .gesture(RightClickGesture { editingSlot = EditingSlot(id: index) })
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
        .background(Color(white: 0.95))
        // Sits on the same light grey strip as the input bar, so keep the
        // button text dark in dark mode too.
        .environment(\.colorScheme, .light)
        .sheet(item: $editingSlot) { slot in
            MacroEditorView(macro: settings.macros[slot.id]) { edited in
                settings.macros[slot.id] = edited
                settings.saveMacros()
            }
        }
    }
}

/// Sheet for editing one macro's title and message.
private struct MacroEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var message: String
    private let onSave: (Macro) -> Void

    init(macro: Macro, onSave: @escaping (Macro) -> Void) {
        _title = State(initialValue: macro.title)
        _message = State(initialValue: macro.message)
        self.onSave = onSave
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                TextField("Title:", text: $title)
                TextField("Message:", text: $message, axis: .vertical)
                    .lineLimit(3...6)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(Macro(title: trimmedTitle, message: message))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Reports a right (secondary) click. SwiftUI's own tap gestures only
/// respond to the primary button, so this wraps an AppKit click recognizer.
private struct RightClickGesture: NSGestureRecognizerRepresentable {
    let action: () -> Void

    func makeNSGestureRecognizer(context: Context) -> NSClickGestureRecognizer {
        let recognizer = NSClickGestureRecognizer()
        recognizer.buttonMask = 0x2 // secondary button
        return recognizer
    }

    func handleNSGestureRecognizerAction(_ recognizer: NSClickGestureRecognizer, context: Context) {
        action()
    }
}

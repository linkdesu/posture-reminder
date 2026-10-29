import SwiftUI
import UIKit

/// The number field of a settings row: a `UITextField` that selects its whole value when editing
/// begins, so the next keystroke replaces the old number instead of appending to it.
///
/// SwiftUI's `TextField` has no selection control before iOS 18, and a number pad cannot place a
/// caret inside "25" anyway, so the row's editing surface is this small representable. The commit
/// rule stays with the caller: leaving the field calls `onCommit`, where an empty or unparsable entry
/// is dropped in favour of the value the row already held.
struct SelectAllNumberField: UIViewRepresentable {
  /// What the field shows. Only ever written by the field while it is being edited.
  @Binding var text: String
  /// Whether the field currently holds focus; the row uses it to avoid overwriting a live edit.
  @Binding var isEditing: Bool
  let accessibilityLabel: String
  /// Called with the field's text when editing ends, so the commit never races the binding.
  let onCommit: (String) -> Void

  func makeUIView(context: Context) -> UITextField {
    let field = SelectAllTextField()
    field.delegate = context.coordinator
    field.keyboardType = .numberPad
    field.textAlignment = .right
    field.borderStyle = .roundedRect
    field.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
    field.accessibilityLabel = accessibilityLabel
    field.text = text
    field.addTarget(context.coordinator,
                    action: #selector(Coordinator.editingChanged(_:)),
                    for: .editingChanged)
    // A number pad has no return key, so the field carries its own way out. It is a UIKit
    // accessory because the field's first responder is a UIKit one; a SwiftUI keyboard toolbar
    // belongs to SwiftUI's own fields and does not appear for this one.
    let toolbar = UIToolbar()
    toolbar.sizeToFit()
    let done = UIBarButtonItem(title: "完成",
                               style: .done,
                               target: context.coordinator,
                               action: #selector(Coordinator.finish))
    done.accessibilityLabel = "完成"
    toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                     done]
    field.inputAccessoryView = toolbar
    return field
  }

  func updateUIView(_ field: UITextField, context: Context) {
    context.coordinator.parent = self
    field.accessibilityLabel = accessibilityLabel
    // A stepper press or a restored default writes the row's value; a live edit keeps what is typed.
    if !field.isFirstResponder, field.text != text {
      field.text = text
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: SelectAllNumberField
    /// Whether the next character typed after focus replaces the whole value instead of landing at a
    /// caret. The visible selection can be lost to the tap that began editing, so the replacement is
    /// enforced on the keystroke itself and not left to `selectAll` alone.
    private var replacesOnNextKeystroke = false

    init(parent: SelectAllNumberField) {
      self.parent = parent
    }

    func textFieldDidBeginEditing(_ field: UITextField) {
      parent.isEditing = true
      replacesOnNextKeystroke = true
      // The whole number, not a caret: typing replaces it.
      field.selectAll(nil)
    }

    func textField(_ field: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
      guard replacesOnNextKeystroke else { return true }
      replacesOnNextKeystroke = false
      // The first key replaces everything, so "25" plus "7" is 7, not 257. A delete (empty string)
      // clears the field, which the commit rules then read as "no number".
      field.text = string
      parent.text = string
      return false
    }

    @objc func editingChanged(_ field: UITextField) {
      parent.text = field.text ?? ""
    }

    /// The keyboard toolbar's 完成: resigning first responder is what ends editing and commits.
    @objc func finish() {
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                      to: nil, from: nil, for: nil)
    }

    func textFieldDidEndEditing(_ field: UITextField) {
      parent.isEditing = false
      parent.onCommit(field.text ?? "")
    }

    /// A number pad has no return key; the keyboard's 完成 does the same thing by resigning first
    /// responder, which ends editing and commits.
    func textFieldShouldReturn(_ field: UITextField) -> Bool {
      field.resignFirstResponder()
      return true
    }
  }
}

/// A text field that answers a tap by selecting its whole value.
///
/// `textFieldDidBeginEditing` alone is not enough: the tap that begins editing also places a caret
/// at the tapped point, after the delegate has run, which collapses the selection `selectAll` just
/// made. Selecting again at the end of the touch — and after becoming first responder — leaves the
/// whole number highlighted, so the first typed digit replaces it instead of appending to it.
private final class SelectAllTextField: UITextField {
  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { selectAll(nil) }
    return became
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    guard isFirstResponder else { return }
    // After UIKit has placed the caret for this touch.
    DispatchQueue.main.async { [weak self] in
      self?.selectAll(nil)
    }
  }
}

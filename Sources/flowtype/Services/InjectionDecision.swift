import Foundation

/// Where a finished transcript should be delivered. Two outcomes only.
enum InjectionDecision: Equatable {
    case inject     // type into the focused field
    case clipboard  // copy + play sound (no usable text destination, or inject unsafe)
}

/// Classification of the system-wide focused element at delivery time.
enum FocusKind: Equatable {
    case editableText    // an editable text field/area (or settable value)
    case nonTextControl  // a clearly non-text control: button, menu, slider, link, image…
    case blindOrUnknown  // no element, generic container, AXUnknown, or AX timed out
}

/// Observable signals gathered just before delivery. Plain data so `decideInjection`
/// stays a pure function (unit-testable without a live AX/system query).
struct FocusSignals: Equatable {
    var secureInputActive: Bool   // IsSecureEventInputEnabled() OR an AXSecureTextField focus
    var focus: FocusKind
}

/// AX roles that mean "you can type text here".
let editableTextRoles: Set<String> = [
    "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
]

/// AX roles that mean "this is a focusable control you clearly cannot type into".
/// Reaching one of these is a positive signal to divert to the clipboard.
let nonTextControlRoles: Set<String> = [
    "AXButton", "AXMenuButton", "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem",
    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXLink",
    "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXImage",
]

/// Pure role/settable → kind. Editable roles win first; then known non-text controls
/// (so a settable slider value is NOT mistaken for text); then a settable generic value
/// (catches web/contentEditable/custom editors that report a non-text role); else blind.
func classifyFocus(role: String?, isValueSettable: Bool) -> FocusKind {
    if let role, editableTextRoles.contains(role) { return .editableText }
    if let role, nonTextControlRoles.contains(role) { return .nonTextControl }
    if isValueSettable { return .editableText }
    return .blindOrUnknown
}

/// Pure decision ladder (spec §4 rows 0–3). Row 4 (inject-then-fail) is handled at runtime.
func decideInjection(_ s: FocusSignals) -> InjectionDecision {
    if s.secureInputActive { return .clipboard }   // row 0: OS would drop the keys
    switch s.focus {
    case .editableText:   return .inject            // row 1
    case .nonTextControl: return .clipboard         // row 2
    case .blindOrUnknown: return .inject            // row 3: fail open (terminals/Electron)
    }
}

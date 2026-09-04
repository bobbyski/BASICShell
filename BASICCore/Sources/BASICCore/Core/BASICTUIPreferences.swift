import Foundation
import TUIKit

// Preferences: the store, the aligned form, and the paged dialog that edits
// them — the three things GallerySettings.swift is made of.
//
// `Form` and `Field` are result builders in Swift, which BASIC has no shape
// for. TUIKit anticipated this and gives both a non-builder face "for
// imperative clients and language bridges"; these handles collect their parts
// and build through that face, the way TUIDialog and TUIWizard already do.

extension BASICRuntime {

    /// Builds a preferences handle, or returns false when `typeName` is not one.
    @MainActor
    static func tuiPreferencesObject(
        typeName: String, title: String, registry: BASICTUIRegistry
    ) throws -> Bool {
        let id = registry.lastAllocatedID
        switch typeName.uppercased() {
        case "TUIPREFS":
            // A suite name keeps a program's settings out of everyone else's,
            // which is what `Preferences(suite:)` is for.
            registry.preferences[id] = Preferences(
                store: .system(suite: title.isEmpty ? nil : title)
            )

        case "TUIFORM":
            // Fields are fixed at construction, so the handle collects them
            // and the Form is built where it is used.
            registry.formFields[id] = []

        case "TUIPREFSDIALOG":
            let dialog = PreferencesDialog(
                title: title.isEmpty ? "Preferences" : title, style: .toolbar
            )
            registry.preferencesDialogs[id] = dialog

        default:
            return false
        }
        return true
    }

    /// The Form a `TUIFORM` handle stands for, built from what it collected.
    ///
    /// Spacing 0, as the gallery's two forms ask for: a preferences page is
    /// short enough that blank rows between fields read as gaps rather than
    /// as breathing room.
    @MainActor
    static func materializeTUIForm(id: Int, registry: BASICTUIRegistry) -> Form? {
        guard let fields = registry.formFields[id] else { return nil }
        let form = Form(spacing: 0, entries: fields)
        registry.views[id] = form
        return form
    }

    /// Dispatches a preferences method, or returns nil when it is not one.
    @MainActor
    static func callTUIPreferencesMethod(
        typeName: String,
        id: Int,
        method: String,
        arguments: [BASICValue],
        registry: BASICTUIRegistry
    ) throws -> BASICValue? {
        func text(_ index: Int) -> String? {
            guard index < arguments.count else { return nil }
            return arguments[index].string?.description
        }
        func number(_ index: Int) -> Int? {
            guard index < arguments.count, let value = arguments[index].number else { return nil }
            return Int(value)
        }
        func handle(_ index: Int) -> Int? {
            guard index < arguments.count,
                  case .systemObject(_, let other) = arguments[index] else { return nil }
            return other
        }

        // ------------------------------------------------------------ store
        if let store = registry.preferences[id] {
            switch method.uppercased() {
            case "TEXT":
                guard let key = text(0) else {
                    throw BASICError.runtime("\(typeName).text expects a key")
                }
                // "" for absent rather than a null: BASIC has no optional, and
                // the caller's fallback reads better as a plain comparison.
                return .string(BASICString(store.string(forKey: key) ?? ""))

            case "SETTEXT":
                guard let key = text(0), let value = text(1) else {
                    throw BASICError.runtime("\(typeName).settext expects a key and a value")
                }
                store.set(value, forKey: key)
                return .empty

            case "FLAG":
                guard let key = text(0) else {
                    throw BASICError.runtime("\(typeName).flag expects a key")
                }
                // The default is the caller's, because `bool(forKey:) ?? X`
                // differs per key — the gallery wants false for one and true
                // for the other.
                let fallback = (number(1) ?? 0) != 0
                return .number((store.bool(forKey: key) ?? fallback) ? 1 : 0)

            case "SETFLAG":
                guard let key = text(0), let value = number(1) else {
                    throw BASICError.runtime("\(typeName).setflag expects a key and 0 or 1")
                }
                store.set(value != 0, forKey: key)
                return .empty

            default:
                throw BASICError.runtime("\(typeName) has no method \(method)")
            }
        }

        // ------------------------------------------------------------- form
        if registry.formFields[id] != nil {
            switch method.uppercased() {
            case "FIELD":
                guard let title = text(0), let viewID = handle(1) else {
                    throw BASICError.runtime("\(typeName).field expects a title and a view")
                }
                // A form may hold a form, so a nested handle is built first.
                let child = registry.views[viewID]
                    ?? Self.materializeTUIForm(id: viewID, registry: registry)
                guard let child else {
                    throw BASICError.runtime("\(typeName).field expects a view")
                }
                registry.formFields[id]?.append(.field(Field(title, view: child)))
                return .empty

            case "SECTION":
                // `Section("Account") { ... }` is builder-only, but the entries
                // it emits are not: a header row, then the fields under it, all
                // sharing the form's one label column. So a section is opened
                // and the fields that follow fall under it.
                guard let title = text(0) else {
                    throw BASICError.runtime("\(typeName).section expects a title")
                }
                registry.formFields[id]?.append(.header(title))
                return .empty

            default:
                throw BASICError.runtime("\(typeName) has no method \(method)")
            }
        }

        // ----------------------------------------------------------- dialog
        if let dialog = registry.preferencesDialogs[id] {
            switch method.uppercased() {
            case "ADDPAGE":
                guard let title = text(0), let icon = text(1), let contentID = handle(2) else {
                    throw BASICError.runtime(
                        "\(typeName).addpage expects a title, an icon and a view"
                    )
                }
                let content = registry.views[contentID]
                    ?? Self.materializeTUIForm(id: contentID, registry: registry)
                guard let content else {
                    throw BASICError.runtime("\(typeName).addpage expects a view")
                }
                _ = dialog.addPage(title, icon: icon.first ?? "•", content: content)
                return .empty

            case "ADDBUTTON":
                guard let title = text(0) else {
                    throw BASICError.runtime("\(typeName).addbutton expects a title")
                }
                let handler = text(2)
                _ = dialog.addButton(title, isDefault: (number(1) ?? 0) != 0) {
                    guard let handler else { return }
                    BASICTUIRuntimeBridge.shared.invoke(handlerNamed: handler)
                }
                return .empty

            default:
                throw BASICError.runtime("\(typeName) has no method \(method)")
            }
        }

        return nil
    }
}

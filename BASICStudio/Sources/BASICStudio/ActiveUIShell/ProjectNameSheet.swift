//
//  ProjectNameSheet.swift
//  BASICStudio
//
//  The sheet that asks for a name: New File…, New Folder…, Rename…, Move….
//

import ActiveUI
import Foundation

/// Asks for one name in a sheet, on the Mac and on iPhone and iPad alike (BASIC-72):
/// the project's New File…, New Folder…, Rename… and Move… use it.
///
/// ```text
///   ┌ Rename main.bas ─────────────────┐
///   │ [ game.bas                     ] │   Return or OK answers; Cancel is nil
///   │                  [Cancel] [ OK ] │
///   └──────────────────────────────────┘
/// ```
@MainActor
enum ProjectNameSheet {
    /// The name typed, or nil when cancelled.
    static func ask(title: String, initial: String) async -> String? {
        let field = AUITextField(initial)
        let answer: String? = await AUISheet.present(contentSize: CGSize(width: 420, height: 150)) { finish in
            AUIStack(.vertical, spacing: 12, alignment: .fill) {
                AUILabel(title).font(.headline)
                field.onSubmit { finish($0) }
                AUIStack(.horizontal, spacing: 8, alignment: .center) {
                    AUIButton("Cancel") { finish(nil) }
                    AUIButton("OK") { finish(field.text) }.defaultButton()
                }
            }
            .padding(16)
        }
        return answer
    }
}

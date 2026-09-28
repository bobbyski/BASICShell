// BASICCore is built on the shared front end. Re-exporting it means every
// file in this module — and every client of BASICCore, which already used
// BASICKeywords, BASICDiagnostic, and the syntax tokenizer — sees the syntax
// types without a second import.
@_exported import BASICSyntax
// And the sound model, so a host can hand the interpreter a
// `BASICToneSynthesizer` without importing a second module.
@_exported import BASICSound

// Foundation also declares an `Expression` (its predicate-builder type). This
// module means the BASIC one; the alias makes bare `Expression` unambiguous
// everywhere in BASICCore.
typealias Expression = BASICSyntax.Expression

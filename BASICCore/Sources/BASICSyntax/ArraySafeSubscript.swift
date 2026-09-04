import Foundation

extension Array {
    /// The element at `index`, or nil when the index is out of range.
    public subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

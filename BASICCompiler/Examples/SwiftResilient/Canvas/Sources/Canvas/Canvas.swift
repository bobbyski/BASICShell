/// A widget in a resilient framework. Its stored properties could grow in a
/// later release without breaking a subclass compiled against this one; that
/// promise is what makes a subclass's field offsets a run-time fact.
open class Widget {
    public var name: String
    public var visible: Bool = true

    public init(name: String) {
        self.name = name
    }

    /// How wide the widget is, in points. Subclasses say.
    open func width() -> Double { 1 }

    /// What the widget calls itself.
    open func label() -> String { name }

    /// Calls both overridable methods, so a subclass's answers show here.
    public func summary() -> String {
        "\(label()) is \(Int(width())) wide"
    }
}

/// A small framework, written as any Swift framework is.
///
/// The BASIC program next door imports it and drives it. Nothing in this file
/// is written for BASIC's benefit: `basicc` reads the symbol graph SwiftPM
/// already produces and calls these methods by their own mangled symbols.
open class Shape {
    public var name: String
    /// An enum-typed property, which crosses through a shim both ways.
    public var tint: Tint = .red

    public init(name: String) { self.name = name }

    /// Overridden below — and the override is what BASIC gets when it calls
    /// `describe()`, because the dispatch happens inside Swift.
    open func area() -> Double { 0 }

    public func describe() -> String { "\(name) has area \(area())" }

    public func rename(_ to: String) { name = to }

    /// An enum parameter (E2).
    public func painted(_ colour: Tint) -> String { "\(name) painted \(colour)" }

    public func sides() -> Int { 0 }

    /// A method that suspends. BASIC calls it and waits; the suspension is
    /// Swift's own (R3.3).
    public func measured() async -> Double {
        try? await Task.sleep(nanoseconds: 20_000_000)
        return area() * 2
    }

    /// Arrays crossing both ways (R4.7). Nothing here is written for
    /// BASIC either: these are the `[String]` and `[Double]` any Swift
    /// caller would pass, and BASIC hands over one of its own arrays.
    public func labelled(_ labels: [String]) -> [String] {
        labels.map { "\($0) is \(name)" }
    }

    public func areas(scaledBy factors: [Double]) -> [Double] {
        factors.map { area() * $0 }
    }

    /// A method that can fail, so the error round trip has something to
    /// carry (R4.6). BASIC catches this with `ON ERROR`.
    public func scaled(by factor: Double) throws -> Double {
        guard factor > 0 else { throw ShapeError.badScale(factor) }
        return area() * factor
    }
}

/// A control with an event, so a BASIC handler has somewhere to be stored
/// (R4.5). `onTap` holds a Swift closure — not a wrapper, not a bridge.
public final class Button {
    /// Nested, so the import has to name `Button.Style` without a dot.
    public enum Style { case plain, bold }
    public var label: String
    public var style: Style = .plain
    private var onTap: (() -> Void)?

    public init(label: String) { self.label = label }

    public func whenTapped(_ handler: @escaping () -> Void) { onTap = handler }

    public func tap() { onTap?() }
}

/// A plain enum, so an imported one has something to be (E2). BASIC sees
/// an ordinary `ENUM Tint` whose members count from 0 in case order.
public enum Tint { case red, green, blue }

/// The framework's own error type. Nothing about it is written for BASIC.
public enum ShapeError: Error {
    case badScale(Double)
}

public final class Rect: Shape {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
        super.init(name: "rect")
    }

    public override func area() -> Double { width * height }
    public override func sides() -> Int { 4 }
}

public final class Circle: Shape {
    public var radius: Double

    public init(radius: Double) {
        self.radius = radius
        super.init(name: "circle")
    }

    public override func area() -> Double { 3.141592653589793 * radius * radius }
}

/// Deliberately left un-importable, so the report has something to say:
/// `[Shape]` has no BASIC spelling yet.
public func totalArea(_ shapes: [Shape]) -> Double { shapes.reduce(0) { $0 + $1.area() } }

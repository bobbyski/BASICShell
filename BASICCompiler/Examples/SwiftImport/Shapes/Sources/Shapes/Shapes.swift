/// A small framework, written as any Swift framework is.
///
/// The BASIC program next door imports it and drives it. Nothing in this file
/// is written for BASIC's benefit: `basicc` reads the symbol graph SwiftPM
/// already produces and calls these methods by their own mangled symbols.
open class Shape {
    public var name: String

    public init(name: String) { self.name = name }

    /// Overridden below — and the override is what BASIC gets when it calls
    /// `describe()`, because the dispatch happens inside Swift.
    open func area() -> Double { 0 }

    public func describe() -> String { "\(name) has area \(area())" }

    public func rename(_ to: String) { name = to }

    public func sides() -> Int { 0 }

    /// A method that suspends. BASIC calls it and waits; the suspension is
    /// Swift's own (R3.3).
    public func measured() async -> Double {
        try? await Task.sleep(nanoseconds: 20_000_000)
        return area() * 2
    }

    /// A method that can fail, so the error round trip has something to
    /// carry (R4.6). BASIC catches this with `ON ERROR`.
    public func scaled(by factor: Double) throws -> Double {
        guard factor > 0 else { throw ShapeError.badScale(factor) }
        return area() * factor
    }
}

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

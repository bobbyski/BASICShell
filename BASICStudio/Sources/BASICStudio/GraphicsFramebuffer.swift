import BASICCore
import AppKit
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

final class GraphicsFramebuffer {
    private(set) var mode = BASICScreenMode(number: 0, width: 0, height: 0, colorCount: 0)
    private(set) var pixels: [Int] = []
    var currentColor = 1

    var isEnabled: Bool {
        mode.width > 0 && mode.height > 0
    }

    func setMode(_ mode: BASICScreenMode) {
        let resolvedMode = mode.width > 0 && mode.height > 0
            ? mode
            : BASICScreenMode(number: mode.number, width: 1024, height: 768, colorCount: 16)
        self.mode = resolvedMode
        pixels = Array(repeating: 0, count: max(0, resolvedMode.width * resolvedMode.height))
    }

    func ensureNativeMode() {
        guard !isEnabled else { return }
        setMode(BASICScreenMode(number: 0, width: 0, height: 0, colorCount: 0))
    }

    func setScreenModeIfNeeded(_ mode: BASICScreenMode) {
        guard !isEnabled else { return }
        setMode(mode)
    }

    func resetMode(_ mode: BASICScreenMode) {
        self.mode = mode
        pixels = Array(repeating: 0, count: max(0, mode.width * mode.height))
    }

    func clear(color: Int?) {
        guard isEnabled else { return }
        pixels = Array(repeating: color ?? 0, count: mode.width * mode.height)
    }

    func setPixel(x: Int, y: Int, color: Int) {
        ensureNativeMode()
        guard isEnabled, x >= 0, y >= 0, x < mode.width, y < mode.height else { return }
        pixels[y * mode.width + x] = normalized(color)
    }

    func getPixel(x: Int, y: Int) -> Int {
        guard isEnabled, x >= 0, y >= 0, x < mode.width, y < mode.height else { return 0 }
        return pixels[y * mode.width + x]
    }

    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        var x = x1
        var y = y1
        let dx = abs(x2 - x1)
        let sx = x1 < x2 ? 1 : -1
        let dy = -abs(y2 - y1)
        let sy = y1 < y2 ? 1 : -1
        var error = dx + dy

        while true {
            setPixel(x: x, y: y, color: color)
            if x == x2 && y == y2 { break }
            let nextError = 2 * error
            if nextError >= dy {
                error += dy
                x += sx
            }
            if nextError <= dx {
                error += dx
                y += sy
            }
        }
    }

    func drawCircle(cx: Int, cy: Int, radius: Int, color: Int) {
        var x = max(0, radius)
        var y = 0
        var error = 1 - x

        while x >= y {
            setCirclePoints(cx: cx, cy: cy, x: x, y: y, color: color)
            y += 1
            if error < 0 {
                error += 2 * y + 1
            } else {
                x -= 1
                error += 2 * (y - x) + 1
            }
        }
    }

    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: Int) {
        let rx = max(0, radiusX)
        let ry = max(0, radiusY)
        guard rx > 0 || ry > 0 else {
            setPixel(x: cx, y: cy, color: color)
            return
        }

        let steps = max(24, Int(Double(max(rx, ry)) * 8))
        var plotted = Set<Int>()
        for step in 0...steps {
            let angle = (Double(step) / Double(steps)) * Double.pi * 2
            let x = cx + Int((Double(rx) * cos(angle)).rounded())
            let y = cy + Int((Double(ry) * sin(angle)).rounded())
            let key = (y << 16) ^ x
            guard plotted.insert(key).inserted else { continue }
            setPixel(x: x, y: y, color: color)
        }
    }

    private func setCirclePoints(cx: Int, cy: Int, x: Int, y: Int, color: Int) {
        setPixel(x: cx + x, y: cy + y, color: color)
        setPixel(x: cx + y, y: cy + x, color: color)
        setPixel(x: cx - y, y: cy + x, color: color)
        setPixel(x: cx - x, y: cy + y, color: color)
        setPixel(x: cx - x, y: cy - y, color: color)
        setPixel(x: cx - y, y: cy - x, color: color)
        setPixel(x: cx + y, y: cy - x, color: color)
        setPixel(x: cx + x, y: cy - y, color: color)
    }

    func paintFill(x: Int, y: Int, color: Int, borderColor: Int?) -> [(x: Int, y: Int)] {
        guard isEnabled, x >= 0, y >= 0, x < mode.width, y < mode.height else { return [] }
        let fillColor = normalized(color)
        let border = borderColor.map(normalized)
        let startColor = getPixel(x: x, y: y)
        guard startColor != fillColor, border != startColor else { return [] }

        var changed: [(x: Int, y: Int)] = []
        var stack = [(x: x, y: y)]
        var visited = Set<Int>()

        while let point = stack.popLast() {
            guard point.x >= 0, point.y >= 0, point.x < mode.width, point.y < mode.height else { continue }
            let index = point.y * mode.width + point.x
            guard visited.insert(index).inserted else { continue }
            let current = pixels[index]
            if let border, current == border { continue }
            guard current == startColor else { continue }

            pixels[index] = fillColor
            changed.append(point)
            stack.append((point.x + 1, point.y))
            stack.append((point.x - 1, point.y))
            stack.append((point.x, point.y + 1))
            stack.append((point.x, point.y - 1))
        }

        return changed
    }

    private func normalized(_ color: Int) -> Int {
        guard mode.colorCount > 0 else { return max(0, color) }
        return max(0, color) % mode.colorCount
    }
}

import CoreGraphics
import Foundation

/// Cellular automata in crisp cells: panels of Wolfram's elementary automata. Each grid is
/// painted as one small bitmap and scaled up without smoothing.
///
/// Automata is adapted from gart (https://github.com/igr/gart), © 2022 Igor Spasić, BSD 2-Clause License.
extension WallpaperCanvas {
    // MARK: - Automata

    /// Rules worth looking at, with the cells they read on each side: twelve of the 256
    /// three-cell rules and six five-cell ones.
    private static let automatonRules: [(rule: Int, reach: Int)] = [
        (30, 1), (45, 1), (73, 1), (86, 1), (89, 1), (105, 1), (110, 1), (124, 1), (135, 1), (150, 1), (54, 1),
        (57, 1), (838, 2), (209_218, 2), (774_857, 2), (37_788_005, 2), (22_047_073, 2), (1_069_090_987, 2),
    ]

    /// A Mondrian-like layout of panels (after gart's Rule), each running its own elementary
    /// cellular automaton in two tones, time flowing down. Three passes split every panel
    /// that's big enough into four, at random multiples of a gap; each panel then starts its
    /// rule from a random row and skips the first forty generations, so it opens on its
    /// settled texture rather than the noise. Drawn in unit space.
    mutating func paintAutomata() {
        enterUnitSpace()
        let gap = 1000.0 / 10.24
        var panels = [CGRect(x: 0, y: 0, width: unitWidth, height: unitHeight)]
        for _ in 0 ..< 3 {
            panels = panels.flatMap { divide($0, gap: gap) }
        }
        fill(isDark ? base.darkened(0.3) : palette.background)
        let hues = harmony(5, keepingTwin: true)
        context.interpolationQuality = .none
        for panel in panels {
            paintAutomatonPanel(panel, hues: hues)
        }
    }

    /// `panel` split into four at random multiples of `gap`, if it's at least four gaps
    /// wide and tall.
    private mutating func divide(_ panel: CGRect, gap: Double) -> [CGRect] {
        guard panel.width >= gap * 4, panel.height >= gap * 4 else { return [panel] }
        let across = Double(1 + rng.int(below: Int(panel.width / gap) - 1)) * gap
        let down = Double(1 + rng.int(below: Int(panel.height / gap) - 1)) * gap
        let (left, top) = (panel.minX, panel.minY)
        return [
            CGRect(x: left, y: top, width: across, height: down),
            CGRect(x: left + across, y: top, width: panel.width - across, height: down),
            CGRect(x: left, y: top + down, width: across, height: panel.height - down),
            CGRect(x: left + across, y: top + down, width: panel.width - across, height: panel.height - down),
        ]
    }

    private mutating func paintAutomatonPanel(_ panel: CGRect, hues: [ThemeColor]) {
        let cell = 4.0
        let (rule, reach) = rng.pick(Self.automatonRules)
        let columns = Int((panel.width / cell).rounded(.up)), generations = Int((panel.height / cell).rounded(.up))
        let first = (0 ..< columns).map { _ in rng.unit() < 0.5 }
        let history = ElementaryAutomaton(rule: rule, reach: reach).run(from: first, generations: generations + 40)
        let on = rng.pick(hues), off = rng.pick(hues)
        let ink = isDark ? on : on.darkened(0.1)
        let paper = isDark ? muted(off, 0.78) : palette.background.mix(off, 0.15)
        let (paperPixel, inkPixel) = (Self.packed(paper), Self.packed(ink))
        let pixels = Self.pixels(count: columns * generations) { cell in
            history[40 + cell / columns][cell % columns] ? inkPixel : paperPixel
        }
        guard let image = bitmapImage(columns: columns, rows: generations, pixels: pixels) else { return }
        context.saveGState()
        // The gutters between panels are the frame showing through.
        context.clip(to: panel.insetBy(dx: 3.5, dy: 3.5))
        drawUpright(image, in: CGRect(
            x: panel.minX, y: panel.minY, width: Double(columns) * cell, height: Double(generations) * cell
        ))
        context.restoreGState()
    }

    /// A color as one RGBX pixel's bytes, read as a (little-endian) word.
    static func packed(_ color: ThemeColor) -> UInt32 {
        UInt32(color.red8) | UInt32(color.green8) << 8 | UInt32(color.blue8) << 16 | 0xFF00_0000
    }

    /// RGBX pixels for `count` cells, each the packed tone `tone` gives it.
    static func pixels(count: Int, tone: (Int) -> UInt32) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: count * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let words = bytes.bindMemory(to: UInt32.self)
            var cell = 0
            while cell < count {
                words[cell] = tone(cell)
                cell += 1
            }
        }
        return pixels
    }
}

/// A one-dimensional, two-state cellular automaton on a ring of cells, in Wolfram's
/// numbering: a cell's next state is bit v of `rule`, where v reads its neighborhood
/// (`reach` cells on each side) as a binary number, the leftmost cell most significant.
struct ElementaryAutomaton {
    let rule: Int
    let reach: Int

    /// `generations` rows, the first being `first`. The ends of each row wrap around.
    func run(from first: [Bool], generations: Int) -> [[Bool]] {
        let lookup = (0 ..< 1 << (2 * reach + 1)).map { (rule >> $0) & 1 == 1 }
        let count = first.count
        var row = first, history: [[Bool]] = []
        for _ in 0 ..< generations {
            history.append(row)
            row = (0 ..< count).map { column in
                var neighborhood = 0
                for offset in -reach ... reach {
                    neighborhood = neighborhood * 2 + (row[((column + offset) % count + count) % count] ? 1 : 0)
                }
                return lookup[neighborhood]
            }
        }
        return history
    }
}

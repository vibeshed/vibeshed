import CoreGraphics
import Foundation

/// Flat graphic patterns: poster geometry, Mondrian, Truchet tiles, terrazzo and circle
/// packing. They draw in unit space (`WallpaperCanvas+Units`).
extension WallpaperCanvas {
    // MARK: - Bauhaus

    /// A grid of square tiles, each with one flat figure in a contrasting color (quarter
    /// disc, half disc, disc, triangle, stripes, quarter ring or lens) turned to a random side.
    mutating func paintBauhaus() {
        enterUnitSpace()
        // Nine across a display's longer side, whichever way it's turned.
        let size = max(display.width, display.height) / unit / 9
        let columns = Int((unitWidth / size - 0.001).rounded(.up)), left = (unitWidth - CGFloat(columns) * size) / 2
        let rows = Int((unitHeight / size - 0.001).rounded(.up)), top = (unitHeight - CGFloat(rows) * size) / 2
        let hues = harmony(4)
        let strong = [palette.accent, hues.cycling(1), palette.yellow, palette.red]
            .map { muted($0, isDark ? 0.25 : 0.12) }
        let neutrals = [base, surface, isDark ? palette.lighterBackground : palette.darkerBackground]
        let colors = strong + neutrals + [palette.foreground.mix(base, isDark ? 0.35 : 0.15)]
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let tile = CGRect(
                    x: left + CGFloat(column) * size, y: top + CGFloat(row) * size, width: size, height: size
                )
                let back = rng.unit() < 0.6 ? rng.pick(neutrals) : rng.pick(strong)
                var front = rng.pick(colors)
                for _ in 0 ..< 8 where front == back {
                    front = rng.pick(colors)
                }
                let figure = rng.int(below: 7), turns = rng.int(below: 4)
                fillRect(tile.insetBy(dx: -0.4, dy: -0.4), back)
                context.saveGState()
                context.translateBy(x: tile.midX, y: tile.midY)
                context.rotate(by: CGFloat(turns) * .pi / 2)
                context.translateBy(x: -size / 2, y: -size / 2)
                context.addPath(Self.bauhausFigure(figure, size: size))
                context.setFillColor(front.cgColor)
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    /// One of seven figures in a `size` square with its origin at the top-left corner.
    private static func bauhausFigure(_ figure: Int, size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch figure {
        case 0: // quarter disc from a corner
            path.move(to: .zero)
            path.addArc(center: .zero, radius: size, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        case 1: // half disc standing on an edge
            path.addArc(
                center: CGPoint(x: size / 2, y: size), radius: size / 2, startAngle: .pi, endAngle: 2 * .pi,
                clockwise: false
            )
        case 2:
            path.addEllipse(in: CGRect(x: size * 0.14, y: size * 0.14, width: size * 0.72, height: size * 0.72))
        case 3:
            path.addLines(between: [.zero, CGPoint(x: size, y: 0), CGPoint(x: 0, y: size)])
        case 4:
            for stripe in 0 ..< 3 {
                path.addRect(CGRect(x: 0, y: CGFloat(stripe) * size / 3 + size / 12, width: size, height: size / 6))
            }
        case 5: // quarter ring
            path.addArc(center: .zero, radius: size, startAngle: 0, endAngle: .pi / 2, clockwise: false)
            path.addArc(center: .zero, radius: size / 2, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        default: // lens between two corner arcs
            path.addArc(center: .zero, radius: size, startAngle: 0, endAngle: .pi / 2, clockwise: false)
            path.addArc(
                center: CGPoint(x: size, y: size), radius: size, startAngle: .pi, endAngle: .pi * 1.5,
                clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }

    // MARK: - De Stijl

    /// Piet Mondrian's compositions: the canvas split recursively into rectangles, a few
    /// filled with the palette's red, blue and yellow, all ruled with heavy lines.
    mutating func paintDeStijl() {
        enterUnitSpace()
        var panels: [CGRect] = []
        splitMondrian(CGRect(x: 0, y: 0, width: unitWidth, height: unitHeight), depth: 0, into: &panels)
        let paper = palette.background, shade = isDark ? palette.lighterBackground : palette.darkBackground
        let primaries = [palette.red, palette.blue, palette.yellow].map { muted($0, isDark ? 0.25 : 0.05) }
        var colored = 0
        for panel in panels {
            let roll = rng.unit()
            if roll < 0.24 {
                fillRect(panel, primaries[colored % primaries.count])
                colored += 1
            } else {
                fillRect(panel, roll < 0.34 ? shade : paper)
            }
        }
        context.setStrokeColor((isDark ? palette.darkerBackground : palette.foreground).mix(.black, 0.35).cgColor)
        context.setLineWidth(11)
        for panel in panels {
            context.stroke(panel)
        }
    }

    /// Cuts `area` in two at 28–72% — across its longer side more often — until pieces are
    /// small; the deeper a piece, the likelier it stays whole.
    private mutating func splitMondrian(_ area: CGRect, depth: Int, into panels: inout [CGRect]) {
        let wide = area.width > 240, tall = area.height > 180
        // A canvas spanning several displays gets the extra cuts that keep its pieces screen-sized.
        let level = depth - max(0, Int(log2(spreadArea).rounded()))
        if level > 5 || (!wide && !tall) || (level > 1 && rng.unit() < 0.16 * Double(level)) {
            panels.append(area)
            return
        }
        let vertical = wide && (!tall || rng.unit() < Double(area.width / (area.width + area.height)))
        let cut = CGFloat(rng.between(0.28, 0.72)) * (vertical ? area.width : area.height)
        let parts = area.divided(atDistance: cut, from: vertical ? .minXEdge : .minYEdge)
        splitMondrian(parts.slice, depth: depth + 1, into: &panels)
        splitMondrian(parts.remainder, depth: depth + 1, into: &panels)
    }

    // MARK: - Truchet

    /// Cyril Smith's Truchet tiles: two quarter circles per tile in one of two orientations.
    /// Every region takes the checkerboard color of the grid corners it contains, so bands
    /// and discs alternate cleanly across tiles.
    mutating func paintTruchet() {
        enterUnitSpace()
        let size: CGFloat = 58
        let columns = Int((unitWidth / size).rounded(.up)), rows = Int((unitHeight / size).rounded(.up))
        let hues = harmony(3)
        let tint = muted(hues[0], isDark ? 0.55 : 0.5)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let flipped = rng.int(below: 2) == 1
                // An unflipped tile's discs hold its top-left and bottom-right corners, so its
                // band holds the other parity (and the other way round when flipped).
                let bandTinted = flipped != (row + column).isMultiple(of: 2)
                let tile = CGRect(x: CGFloat(column) * size, y: CGFloat(row) * size, width: size, height: size)
                fillRect(tile.insetBy(dx: -0.4, dy: -0.4), bandTinted ? tint : base)
                context.addPath(Self.truchetDiscs(in: tile, flipped: flipped))
                context.setFillColor((bandTinted ? base : tint).cgColor)
                context.fillPath()
            }
        }
        let low = CGPoint(x: unitWidth * rng.between(0, 0.4), y: unitHeight * rng.between(0.6, 1))
        glow(hues.cycling(1), at: low, radius: 900, alpha: isDark ? 0.22 : 0.16)
        let high = CGPoint(x: unitWidth * rng.between(0.6, 1), y: unitHeight * rng.between(0, 0.4))
        glow(hues.cycling(2), at: high, radius: 800, alpha: isDark ? 0.16 : 0.12)
    }

    /// The quarter discs of a Smith tile: on the top-left and bottom-right corners or, when
    /// flipped, the top-right and bottom-left.
    private static func truchetDiscs(in tile: CGRect, flipped: Bool) -> CGPath {
        let corners: [(point: CGPoint, start: CGFloat)] = flipped
            ? [(CGPoint(x: tile.maxX, y: tile.minY), .pi / 2), (CGPoint(x: tile.minX, y: tile.maxY), .pi * 1.5)]
            : [(CGPoint(x: tile.minX, y: tile.minY), 0), (CGPoint(x: tile.maxX, y: tile.maxY), .pi)]
        let path = CGMutablePath()
        for corner in corners {
            path.move(to: corner.point)
            path.addArc(
                center: corner.point, radius: tile.width / 2, startAngle: corner.start,
                endAngle: corner.start + .pi / 2, clockwise: false
            )
            path.closeSubpath()
        }
        return path
    }

    // MARK: - Terrazzo

    /// Stone chips of every size, mostly small, scattered without touching over a softly
    /// mottled ground.
    mutating func paintTerrazzo() {
        enterUnitSpace()
        fill(palette.background)
        let mottle = isDark ? palette.lighterBackground : palette.darkBackground
        for _ in 0 ..< Int((7 * spreadArea).rounded()) {
            let spot = CGPoint(x: unitWidth * rng.unit(), y: unitHeight * rng.unit())
            glow(mottle, at: spot, radius: rng.between(220, 520), alpha: 0.5)
        }
        let stones = harmony(4).enumerated().map { index, hue in
            muted(hue, isDark ? 0.3 + 0.06 * Double(index) : 0.15 + 0.05 * Double(index))
        } + [
            muted(palette.foreground, isDark ? 0.45 : 0.5),
            isDark ? palette.darkerBackground : palette.background.mix(.white, 0.7),
        ]
        var placed: [(center: CGPoint, radius: CGFloat)] = []
        let tries = Int((6000 * spreadArea).rounded()), most = Int((460 * spreadArea).rounded())
        for _ in 0 ..< tries where placed.count < most {
            let radius = CGFloat(rng.unit() < 0.07 ? rng.between(24, 42) : rng.between(4, 14))
            let center = CGPoint(x: rng.between(-20, unitWidth + 20), y: rng.between(-20, unitHeight + 20))
            let crowded = placed.contains { other in
                hypot(other.center.x - center.x, other.center.y - center.y) < other.radius + radius + 4
            }
            if crowded { continue }
            placed.append((center, radius))
            let stone = chip(at: center, radius: radius)
            context.addPath(stone)
            context.setFillColor(rng.pick(stones).cgColor)
            context.fillPath()
        }
    }

    /// An irregular 5–8-sided stone.
    private mutating func chip(at center: CGPoint, radius: CGFloat) -> CGPath {
        let sides = 5 + rng.int(below: 4), spin = rng.between(0, 2 * .pi)
        let corners = (0 ..< sides).map { side in
            let angle = spin + (Double(side) + rng.between(-0.3, 0.3)) / Double(sides) * 2 * .pi
            let reach = radius * rng.between(0.55, 1)
            return CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
        }
        let path = CGMutablePath()
        path.addLines(between: corners)
        path.closeSubpath()
        return path
    }

    // MARK: - Circle packing

    /// Circles grown at random spots until they nearly touch, big ones first; some solid,
    /// some ringed like targets, some outlined around a dot.
    mutating func paintCircles() {
        enterUnitSpace()
        fill(base)
        let circles = packCircles()
        let tones = harmony(4).enumerated().map { index, hue in
            muted(hue, isDark ? 0.3 + 0.08 * Double(index) : 0.2 + 0.06 * Double(index))
        } + [
            isDark ? palette.lighterBackground : palette.darkBackground,
            muted(palette.foreground, isDark ? 0.55 : 0.5),
        ]
        for circle in circles {
            let tone = rng.pick(tones), look = rng.unit()
            context.setFillColor(tone.cgColor)
            if look < 0.55 || circle.radius < 14 {
                disc(at: circle.center, radius: circle.radius)
            } else if look < 0.8 {
                let rings = max(2, Int(circle.radius / 14))
                for ring in 0 ..< rings {
                    context.setFillColor((ring.isMultiple(of: 2) ? tone : base).cgColor)
                    disc(at: circle.center, radius: circle.radius * (1 - CGFloat(ring) / CGFloat(rings)))
                }
            } else {
                let weight = max(2, circle.radius * 0.08), inner = circle.radius - weight / 2
                context.setStrokeColor(tone.cgColor)
                context.setLineWidth(weight)
                context.strokeEllipse(in: CGRect(
                    x: circle.center.x - inner, y: circle.center.y - inner, width: inner * 2, height: inner * 2
                ))
                disc(at: circle.center, radius: circle.radius * 0.35)
            }
        }
    }

    /// Random spots, each circle as large as the room around it allows (less a gap), in
    /// rounds with a shrinking size limit so the big circles land first.
    private mutating func packCircles() -> [(center: CGPoint, radius: CGFloat)] {
        let rounds: [(largest: CGFloat, tries: Int)] = [
            (220, 18), (140, 60), (90, 160), (55, 400), (32, 900), (18, 1600), (10, 2400),
        ]
        var placed: [(center: CGPoint, radius: CGFloat)] = []
        for round in rounds {
            for _ in 0 ..< Int((Double(round.tries) * spreadArea).rounded()) {
                let center = CGPoint(x: unitWidth * rng.unit(), y: unitHeight * rng.unit())
                var room = round.largest
                for other in placed {
                    room = min(room, hypot(other.center.x - center.x, other.center.y - center.y) - other.radius - 4)
                    if room < 6 { break }
                }
                if room >= 6 { placed.append((center, room * rng.between(0.8, 1))) }
            }
        }
        return placed
    }
}

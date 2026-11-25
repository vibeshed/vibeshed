import CoreGraphics
import Foundation

/// Flow: evenly spaced streamlines through a noise field, drawn as tapering ribbons around a
/// disc. Drawn in unit space.
///
/// Adapted from gart (https://github.com/igr/gart), © 2022 Igor Spasić, BSD 2-Clause License.
extension WallpaperCanvas {
    /// A calm field of evenly spaced streamlines across the whole screen (after gart's
    /// perl), placed the way Jobard and Lefer do in "Creating Evenly-Spaced Streamlines of
    /// Arbitrary Density" (1997): each new line starts one separation away from an
    /// accepted one and stops before it comes within half that of any other, then tapers
    /// where it crowded in. Width and color follow a slow wave across the page; one line in
    /// six is a string of beads. A disc sits among them, and the lines below it pass in front.
    mutating func paintFlow() {
        enterUnitSpace()
        fill(base)
        let frequency = rng.between(0.0009, 0.0014), turns = rng.between(0.9, 1.3)
        let offset = (x: rng.between(0, 500), y: rng.between(0, 500)), swirl = rng.between(0, 2 * .pi)
        let separation = rng.between(12, 15)
        let area = CGRect(x: 0, y: 0, width: unitWidth, height: unitHeight)
            .insetBy(dx: -separation * 2, dy: -separation * 2)
        let noise = self.noise
        let field = SampledField(over: area, spacing: 10) { x, y in
            noise.fractal(x * frequency + offset.x, y * frequency + offset.y, octaves: 3)
        }
        let placer = StreamlinePlacer(bounds: area, separation: separation) { x, y in
            swirl + (field.value(x, y) - 0.5) * 2 * .pi * turns
        }
        paintStreamlines(placer.place(using: &rng), separation: separation)
    }

    /// The lines from top to bottom (by their middles), the disc dropped in once they pass
    /// its center.
    private mutating func paintStreamlines(_ lines: [Streamline], separation: Double) {
        let hues = harmony(4, keepingTwin: true)
        let ramp = [
            muted(hues.count > 2 ? hues[2] : hues.cycling(1), 0.45), muted(hues.cycling(1), 0.2), hues[0],
            hues[0].mix(palette.foreground, 0.35),
        ]
        let wave = rng.between(0.006, 0.012), phase = rng.between(0, 2 * .pi)
        let disc = (
            center: CGPoint(x: unitWidth * rng.between(0.22, 0.78), y: unitHeight * rng.between(0.38, 0.68)),
            radius: rng.between(95, 135)
        )
        var discDrawn = false
        for line in lines.sorted(by: { $0.middle.y < $1.middle.y }) {
            let along = cos(line.middle.x * wave + phase) * 0.5 + 0.5
            let lineWidth = separation * (0.18 + 0.64 * along), color = ramp.ramp(along)
            if rng.int(below: 6) == 0 {
                context.addPath(Self.beads(line, width: lineWidth))
                context.setFillColor(color.cgColor(alpha: 0.45))
            } else {
                context.addPath(Self.ribbon(
                    line.points,
                    widths: line.taper.map { lineWidth * max(pow($0, 0.6), 0.12) }
                ))
                context.setFillColor(color.cgColor)
            }
            context.fillPath()
            if !discDrawn, line.middle.y > disc.center.y {
                paintFlowDisc(at: disc.center, radius: disc.radius)
                discDrawn = true
            }
        }
        if !discDrawn { paintFlowDisc(at: disc.center, radius: disc.radius) }
    }

    /// The disc, with a ring of background around it so the lines behind stop short of it.
    private func paintFlowDisc(at center: CGPoint, radius: Double) {
        context.setFillColor((isDark ? palette.foreground : palette.foreground.mix(palette.background, 0.1)).cgColor)
        disc(at: center, radius: radius)
        context.setStrokeColor(base.cgColor)
        context.setLineWidth(18)
        context.strokeEllipse(in: CGRect(
            x: center.x - radius - 9,
            y: center.y - radius - 9,
            width: (radius + 9) * 2,
            height: (radius + 9) * 2
        ))
    }

    /// A filled outline around a polyline whose width varies point by point, with round
    /// ends: the two sides as one polygon, the end caps as discs.
    private static func ribbon(_ points: [CGPoint], widths: [Double]) -> CGPath {
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(points.count)
        right.reserveCapacity(points.count)
        for index in points.indices {
            let before = points[max(index - 1, 0)], after = points[min(index + 1, points.count - 1)]
            let length = hypot(after.x - before.x, after.y - before.y)
            let half = widths[index] / 2 / (length == 0 ? 1 : length)
            let normal = CGPoint(x: -(after.y - before.y) * half, y: (after.x - before.x) * half)
            left.append(CGPoint(x: points[index].x + normal.x, y: points[index].y + normal.y))
            right.append(CGPoint(x: points[index].x - normal.x, y: points[index].y - normal.y))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        for index in [0, points.count - 1] {
            let radius = widths[index] / 2
            // A separate subpath winding the same way as the outline, so it adds to the fill.
            path.addPath(CGPath(
                ellipseIn: CGRect(
                    x: points[index].x - radius,
                    y: points[index].y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            ))
        }
        return path
    }

    /// Dots along a line, one every 1.25 widths, shrinking where it tapers.
    private static func beads(_ line: Streamline, width: Double) -> CGPath {
        let path = CGMutablePath()
        var travelled = 0.0
        for index in line.points.indices.dropFirst() {
            let point = line.points[index], previous = line.points[index - 1]
            travelled += hypot(point.x - previous.x, point.y - previous.y)
            guard travelled >= width * 1.25 else { continue }
            travelled = 0
            let radius = width * 0.5 * max(line.taper[index], 0.3)
            path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        return path
    }
}

/// One placed streamline: its points in order, and per point how much room it had, from 0
/// where it stopped against another line to 1 in the open.
struct Streamline {
    let points: [CGPoint]
    let taper: [Double]

    var middle: CGPoint {
        points[points.count / 2]
    }
}

/// Places evenly spaced streamlines in the direction field `direction` (an angle at each
/// point), after gart's flow2/Streamlines.kt. New lines start from seeds one `separation` to
/// each side of every point of every accepted line, then from a shuffled grid of seeds that
/// fills any gaps; a line grows both ways with second-order Runge–Kutta steps until it
/// leaves `bounds` or comes within half a separation of another line (or of itself, away
/// from where it is). Lines shorter than two separations are dropped.
final class StreamlinePlacer {
    let bounds: CGRect
    let separation: Double
    /// The distance a line keeps from every other: half a separation.
    let clearance: Double
    private let step = 1.5
    private let direction: (_ x: Double, _ y: Double) -> Double
    private let points: StreamlinePoints
    private var lines: [(first: Int, middle: Int, end: Int)] = []
    private var seeds: [CGPoint] = []

    init(bounds: CGRect, separation: Double, direction: @escaping (_ x: Double, _ y: Double) -> Double) {
        self.bounds = bounds
        self.separation = separation
        self.direction = direction
        clearance = separation / 2
        points = StreamlinePoints(bounds: bounds, cell: clearance)
    }

    func place(using rng: inout SeededGenerator) -> [Streamline] {
        let columns = Int((bounds.width / separation).rounded(.up))
        let rows = Int((bounds.height / separation).rounded(.up))
        var cover = Array(0 ..< columns * rows)
        for index in cover.indices.reversed() {
            cover.swapAt(index, rng.int(below: index + 1))
        }
        let seedRoom = max(clearance, separation * 0.99)
        var next = 0
        while true {
            let seed: CGPoint
            if !seeds.isEmpty {
                let pick = Int(rng.next() % UInt64(seeds.count))
                seed = seeds[pick]
                seeds.swapAt(pick, seeds.count - 1)
                seeds.removeLast()
            } else if next < cover.count {
                let cell = cover[next]
                next += 1
                seed = CGPoint(
                    x: bounds.minX + (Double(cell % columns) + 0.5) * separation,
                    y: bounds.minY + (Double(cell / columns) + 0.5) * separation
                )
            } else {
                break
            }
            if bounds.contains(seed), points.isFree(seed.x, seed.y, radius: seedRoom, line: -1, arc: 0) {
                grow(from: seed)
            }
        }
        // Every point's room, measured on the lanes now that the points stay put.
        let (points, separation, clearance) = (points, separation, clearance)
        let tapers = LaneBuffer<Double>(zeroed: points.count)
        defer { tapers.deallocate() }
        RenderLanes.split(points.count) { _, ids in
            for id in ids {
                let room = points.room(around: id, within: separation)
                tapers.base[id] = clampUnit((room - clearance) / (separation - clearance))
            }
        }
        return lines.indices.map { line in
            let ids = ids(of: line)
            return Streamline(
                points: ids.map { CGPoint(x: points[$0].x, y: points[$0].y) },
                taper: ids.map { tapers.base[$0] }
            )
        }
    }

    /// Grows a line both ways from `seed`; keeps it and seeds its neighbors if it's long
    /// enough, or takes its points back out.
    private func grow(from seed: CGPoint) {
        let line = Int32(lines.count), first = points.count
        points.add(seed.x, seed.y, arc: 0, line: line)
        let ahead = walk(from: seed, step: step, line: line), middle = points.count
        let behind = walk(from: seed, step: -step, line: line), end = points.count
        guard end - first >= 2, ahead + behind >= separation * 2 else {
            points.removeLast(end - first)
            return
        }
        lines.append((first, middle, end))
        let ids = ids(of: lines.count - 1)
        for (index, id) in ids.enumerated() {
            let before = points[ids[max(index - 1, 0)]], after = points[ids[min(index + 1, ids.count - 1)]]
            let length = hypot(after.x - before.x, after.y - before.y)
            guard length > 0 else { continue }
            let normal = CGPoint(
                x: -(after.y - before.y) / length * separation,
                y: (after.x - before.x) / length * separation
            )
            let point = points[id]
            seeds.append(CGPoint(x: point.x + normal.x, y: point.y + normal.y))
            seeds.append(CGPoint(x: point.x - normal.x, y: point.y - normal.y))
        }
    }

    /// Steps from `start` while there's room, adding points; returns the length walked.
    private func walk(from start: CGPoint, step: Double, line: Int32) -> Double {
        var (x, y) = (start.x, start.y), walked = 0.0, steps = 0
        let length = abs(step)
        while steps < 100_000 {
            let first = direction(x, y)
            let second = direction(x + cos(first) * step * 0.5, y + sin(first) * step * 0.5)
            let nextX = x + cos(second) * step, nextY = y + sin(second) * step
            let arc = step > 0 ? walked + length : -(walked + length)
            guard bounds.contains(CGPoint(x: nextX, y: nextY)),
                  points.isFree(nextX, nextY, radius: clearance, line: line, arc: arc)
            else { break }
            walked += length
            (x, y) = (nextX, nextY)
            points.add(x, y, arc: arc, line: line)
            steps += 1
        }
        return walked
    }

    /// A line's point ids from its far back end to its far front end.
    private func ids(of line: Int) -> [Int] {
        let (first, middle, end) = lines[line]
        return Array((middle ..< end).reversed()) + Array(first ..< middle)
    }
}

/// The placed points in flat storage, bucketed in a grid of `cell`-sized squares through
/// per-cell linked lists, so adding a point and taking the newest ones back out are both
/// constant time. Raw memory rather than arrays: the neighbor scan runs tens of millions
/// of times, and debug builds call a generic accessor for every array subscript. Once
/// placement ends nothing writes to it, and the lanes read it to measure the tapers.
private final class StreamlinePoints: @unchecked Sendable {
    struct Point {
        var x: Double
        var y: Double
        /// Signed distance along its line from the seed.
        var arc: Double
        var line: Int32
        /// The point added before it to the same cell, or −1.
        var link: Int32
    }

    private(set) var count = 0
    private var capacity = 4096
    private var storage: UnsafeMutablePointer<Point>
    private let heads: UnsafeMutablePointer<Int32>
    private let origin: CGPoint
    private let cell: Double
    private let columns: Int
    private let rows: Int

    init(bounds: CGRect, cell: Double) {
        origin = bounds.origin
        self.cell = cell
        columns = Int((bounds.width / cell).rounded(.up))
        rows = Int((bounds.height / cell).rounded(.up))
        heads = .allocate(capacity: columns * rows)
        heads.initialize(repeating: -1, count: columns * rows)
        storage = .allocate(capacity: capacity)
    }

    deinit {
        heads.deallocate()
        storage.deallocate()
    }

    subscript(id: Int) -> Point {
        storage[id]
    }

    func add(_ x: Double, _ y: Double, arc: Double, line: Int32) {
        if count == capacity {
            let grown = UnsafeMutablePointer<Point>.allocate(capacity: capacity * 2)
            grown.moveInitialize(from: storage, count: count)
            storage.deallocate()
            (storage, capacity) = (grown, capacity * 2)
        }
        let bucket = self.bucket(x, y)
        (storage + count).initialize(to: Point(x: x, y: y, arc: arc, line: line, link: heads[bucket]))
        heads[bucket] = Int32(count)
        count += 1
    }

    /// Takes the newest `number` points back out.
    func removeLast(_ number: Int) {
        for id in stride(from: count - 1, through: count - number, by: -1) {
            heads[bucket(storage[id].x, storage[id].y)] = storage[id].link
        }
        count -= number
    }

    /// Whether no point lies within `radius` of (x, y), ignoring the points of `line` within
    /// two clearances of `arc` along it (a line's own last steps).
    func isFree(_ x: Double, _ y: Double, radius: Double, line: Int32, arc: Double) -> Bool {
        nearest(x, y, within: radius, skipping: (line, arc), stopAtFirst: true) >= radius * radius
    }

    /// The distance from point `id` to the nearest point of another line (or of its own,
    /// away from it), capped at `limit`.
    func room(around id: Int, within limit: Double) -> Double {
        let point = storage[id]
        return nearest(point.x, point.y, within: limit, skipping: (point.line, point.arc), stopAtFirst: false)
            .squareRoot()
    }

    /// The squared distance to the nearest point within `limit` (or to any such point, if
    /// `stopAtFirst`), or `limit²` if there's none.
    private func nearest(
        _ x: Double, _ y: Double, within limit: Double, skipping own: (line: Int32, arc: Double), stopAtFirst: Bool
    ) -> Double {
        let reach = Int((limit / cell).rounded(.up)), selfSkip = cell * 2
        let column = clampCell((x - origin.x) / cell, columns), row = clampCell((y - origin.y) / cell, rows)
        let lastRow = min(row + reach, rows - 1), firstColumn = max(column - reach, 0)
        let lastColumn = min(column + reach, columns - 1)
        var best = limit * limit, neighborRow = max(row - reach, 0)
        while neighborRow <= lastRow {
            var neighborColumn = firstColumn
            while neighborColumn <= lastColumn {
                var id = Int(heads[neighborRow * columns + neighborColumn])
                while id >= 0 {
                    let point = storage + id
                    let dx = point.pointee.x - x, dy = point.pointee.y - y, squared = dx * dx + dy * dy
                    if squared < best,
                       point.pointee.line != own.line || abs(point.pointee.arc - own.arc) > selfSkip
                    {
                        if stopAtFirst { return squared }
                        best = squared
                    }
                    id = Int(point.pointee.link)
                }
                neighborColumn += 1
            }
            neighborRow += 1
        }
        return best
    }

    private func bucket(_ x: Double, _ y: Double) -> Int {
        clampCell((y - origin.y) / cell, rows) * columns + clampCell((x - origin.x) / cell, columns)
    }

    private func clampCell(_ position: Double, _ count: Int) -> Int {
        let index = Int(floor(position))
        return index < 0 ? 0 : index >= count ? count - 1 : index
    }
}

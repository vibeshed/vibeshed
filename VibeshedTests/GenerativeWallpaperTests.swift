import CoreGraphics
@testable import Vibeshed
import XCTest

/// The pure parts behind the simulated wallpaper styles.
final class GenerativeWallpaperTests: XCTestCase {
    func testElementaryAutomatonRunsRule30() {
        let rule30 = ElementaryAutomaton(rule: 30, reach: 1)
        let rows = rule30.run(from: (0 ..< 11).map { $0 == 5 }, generations: 5)
            .map { String($0.map { $0 ? "#" : "." }) }
        XCTAssertEqual(rows, [".....#.....", "....###....", "...##..#...", "..##.####..", ".##..#...#."])
        // The row is a ring: a cell at the left edge has a neighbor at the right.
        let edge = rule30.run(from: [true] + Array(repeating: false, count: 6), generations: 2)
        XCTAssertEqual(edge[1], [true, true, false, false, false, false, true])
    }

    func testStreamlinesKeepTheirDistance() {
        let placer = StreamlinePlacer(bounds: CGRect(x: 0, y: 0, width: 160, height: 120), separation: 12) { x, y in
            sin(x * 0.02) * 2 + cos(y * 0.03)
        }
        var rng = SeededGenerator(seed: 7)
        let lines = placer.place(using: &rng)
        XCTAssertGreaterThan(lines.count, 8)
        for line in lines {
            XCTAssertEqual(line.taper.count, line.points.count)
            XCTAssertTrue(line.taper.allSatisfy { (0 ... 1).contains($0) })
        }
        var closest = Double.infinity
        for (index, line) in lines.enumerated() {
            for other in lines[(index + 1)...] {
                for point in line.points {
                    for neighbor in other.points {
                        closest = min(closest, hypot(point.x - neighbor.x, point.y - neighbor.y))
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(closest, placer.clearance, "no two lines come within half a separation")
        XCTAssertLessThan(closest, placer.separation, "and they're packed, not sparse")
    }

    func testChladniSandSettlesOnTheNodalLines() {
        let plate = ChladniPlate(modes: (3, 5), sign: 1, aspect: 1.6)
        var rng = SeededGenerator(seed: 5), random: UInt64 = 11
        var (scattered, settled) = (0, 0)
        for _ in 0 ..< 2000 {
            var x = rng.unit() * plate.aspect, y = rng.unit()
            if abs(plate.value(x: x, y: y)) < 0.1 { scattered += 1 }
            plate.settle(x: &x, y: &y, steps: 60, random: &random)
            if abs(plate.value(x: x, y: y)) < 0.1 { settled += 1 }
        }
        XCTAssertLessThan(scattered, 400, "sand starts out anywhere")
        XCTAssertGreaterThan(settled, 1800, "and ends up where the plate stands still")
    }

    func testCuttingMatComesInEveryColorGreenMostOften() {
        let picks = (0 ..< 1000).map { MatColor.pick(Double($0) / 1000) }
        XCTAssertEqual(Set(picks), Set(MatColor.allCases))
        let counts = Dictionary(grouping: picks, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(counts.max { $0.value < $1.value }?.key, .green)
    }
}

import CoreGraphics
import Foundation

extension WallpaperCanvas.Tone {
    /// The nearest color the Amiga's 12-bit palette (4 bits a channel) can show.
    init(amiga color: ThemeColor) {
        func nibble(_ byte: Int) -> Int {
            Int((Double(byte) / 17).rounded()) * 17
        }
        self.init(red: nibble(color.red8), green: nibble(color.green8), blue: nibble(color.blue8))
    }
}

/// The Amiga's Boing Ball, the 1984 demo that launched the machine: a red and white
/// checkered ball in front of a grid wall with a floor in perspective, casting its shadow on
/// the wall. Drawn as hard-edged pixels (400 rows, like interlaced hi-res) in 12-bit color.
/// The wall is the theme's desktop color, the grid its magenta, the ball its red.
extension WallpaperCanvas {
    mutating func paintBoing() {
        let dot = max(1, (unit * 2.5).rounded())
        let columns = Double(Int((width / dot).rounded(.up))), rows = Double(Int((height / dot).rounded(.up)))
        let wall = palette["desktop"] ?? classicDesktop
        // The red nearest a full-strength one: themes darken `red` for paper or lighten it for ink.
        let red = [palette.red, palette["bright_red"] ?? palette.red]
            .min { abs($0.hsl.lightness - 0.5) < abs($1.hsl.lightness - 0.5) } ?? palette.red
        let tones = [wall, palette.magenta, red, .white]
        let lit = tones.map { Tone(amiga: $0) }
        let shaded = tones.map { Tone(amiga: $0.mix(.black, 0.45)) }
        let grid = BoingGrid(columns: columns, rows: rows)
        let ball = BoingBall(
            center: CGPoint(x: columns * rng.between(0.3, 0.62), y: rows * rng.between(0.34, 0.52)),
            radius: min(rows, columns) * 0.2, tilt: (rng.unit() < 0.5 ? -1 : 1) * rng.between(0.25, 0.42),
            spin: rng.between(0, .pi / 8)
        )
        let shadow = CGPoint(x: ball.center.x + ball.radius * 0.42, y: ball.center.y + ball.radius * 0.1)
        paintPixels(dot: dot) { column, row in
            let x = Double(column) + 0.5, y = Double(row) + 0.5
            if let square = ball.square(x: x, y: y) { return lit[square == .white ? 3 : 2] }
            let background = grid.isLine(x: x, y: y) ? 1 : 0
            let inShadow = hypot(x - shadow.x, y - shadow.y) <= ball.radius
            return inShadow ? shaded[background] : lit[background]
        }
    }
}

/// The wall of square cells and the floor that recedes from its foot, in pixel coordinates.
struct BoingGrid {
    let cell: Double
    let left: Double, right: Double
    let top: Double, floorTop: Double, floorBottom: Double
    let center: Double
    /// How much wider the floor's front edge is than the wall.
    private let spread = 1.3
    /// Where the floor's crosswise lines fall, 0 at the wall and 1 at the front: spaced wider
    /// toward the viewer.
    private let floorLines = [0, 0.2, 0.44, 0.71, 1]

    init(columns: Double, rows: Double) {
        cell = rows * 0.064
        let across = (columns * 0.78 / cell).rounded(.down)
        left = (columns - across * cell) / 2
        right = left + across * cell
        top = rows * 0.07
        floorTop = top + cell * 11
        floorBottom = min(rows * 0.97, floorTop + cell * 3)
        center = columns / 2
    }

    func isLine(x: Double, y: Double) -> Bool {
        if y >= top, y < floorTop + 1, x >= left, x < right + 1 {
            return onGrid(x - left, width: 1) || onGrid(y - top, width: 1)
        }
        guard y >= floorTop, y < floorBottom + 1 else { return false }
        let depth = min((y - floorTop) / (floorBottom - floorTop), 1)
        let scale = 1 + (spread - 1) * depth
        let wallX = (x - center) / scale + center
        guard wallX >= left, wallX < right + 1 / scale else { return false }
        let across = floorLines.contains { abs(y - (floorTop + $0 * (floorBottom - floorTop))) < 0.5 }
        return across || onGrid(wallX - left, width: 1 / scale)
    }

    private func onGrid(_ offset: Double, width: Double) -> Bool {
        offset.truncatingRemainder(dividingBy: cell) < width
    }
}

/// The checkered ball: 8 bands of latitude by 16 of longitude, its axis tilted in the
/// picture plane and turned by `spin`.
struct BoingBall {
    let center: CGPoint
    let radius: Double
    let tilt: Double
    let spin: Double

    enum Square {
        case red, white
    }

    /// The square under the point, or nil off the ball.
    func square(x: Double, y: Double) -> Square? {
        let nx = (x - center.x) / radius, ny = (y - center.y) / radius
        let across = nx * nx + ny * ny
        guard across <= 1 else { return nil }
        let nz = (1 - across).squareRoot()
        let sideways = nx * cos(tilt) - ny * sin(tilt)
        let upright = nx * sin(tilt) + ny * cos(tilt)
        let latitude = asin(min(max(upright, -1), 1)) + .pi / 2
        let longitude = atan2(sideways, nz) + spin + .pi
        let band = Int(latitude / (.pi / 8)), segment = Int(longitude / (.pi / 8))
        return (band + segment) % 2 == 0 ? .white : .red
    }
}

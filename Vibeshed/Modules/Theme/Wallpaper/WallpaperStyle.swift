import Foundation

/// Procedural wallpaper algorithms, each painting purely from a theme palette.
enum WallpaperStyle: String, CaseIterable, Sendable {
    case glow, mesh, waves, ridges, bokeh, lowpoly, topographic, sunset, arcs
    case pulsar, guilloche, sashiko, attractor
    case bauhaus, destijl, truchet, terrazzo, circles, isometric, penrose
    case flow, lens, papercut, automata, chladni
    case leaves, warp, ascii, polyhedra, maze, dither, pipes
    case pebbles, macpattern, pinstripe
    case clouds, azul, winpattern, boing, rain
    case solid

    /// Config value that picks a style per theme (stable, so each theme keeps its look).
    static let automatic = "auto"

    /// What `auto` chooses from.
    static let varied: [WallpaperStyle] = allCases.filter(\.joinsAutomatic)

    /// `varied` laid out as `auto`'s slots were settled. Halftone, since removed, held the
    /// slot before Pulsar; it stays, empty, so every other theme keeps its pick.
    private static let automaticSlots: [WallpaperStyle?] = {
        var slots = varied.map(Optional.some)
        slots.insert(nil, at: varied.firstIndex(of: .pulsar) ?? varied.count)
        return slots
    }()

    /// Whether `auto` may pick this style. Period pieces stay out, since they're made for
    /// their own themes, and so do styles added after the pool was settled: growing it
    /// would reshuffle every theme's stable pick. Those are opt-in, by name.
    var joinsAutomatic: Bool {
        switch self {
        case .solid, .flow, .lens, .papercut, .automata, .chladni: false
        default: !isPeriodPiece
        }
    }

    /// Styles drawn in whole-pixel bitmaps, where film grain would spoil the hard edges.
    var isPixelBitmap: Bool {
        switch self {
        case .pebbles, .macpattern, .pinstripe, .clouds, .winpattern, .boing, .rain: true
        default: false
        }
    }

    /// Recreations of one system's desktop, kept out of `auto`.
    var isPeriodPiece: Bool {
        isPixelBitmap || self == .azul
    }

    var displayName: String {
        switch self {
        case .glow: "Glow"
        case .mesh: "Mesh Gradient"
        case .waves: "Waves"
        case .ridges: "Ridges"
        case .bokeh: "Bokeh"
        case .lowpoly: "Low Poly"
        case .topographic: "Topographic"
        case .sunset: "Retro Sunset"
        case .arcs: "Retro Arcs"
        case .pulsar: "Pulsar"
        case .guilloche: "Guilloché"
        case .sashiko: "Sashiko"
        case .attractor: "Attractor"
        case .bauhaus: "Bauhaus"
        case .destijl: "De Stijl"
        case .truchet: "Truchet"
        case .terrazzo: "Terrazzo"
        case .circles: "Circle Packing"
        case .isometric: "Isometric Terraces"
        case .penrose: "Penrose"
        case .flow: "Flow"
        case .lens: "Lens"
        case .papercut: "Paper Cut"
        case .automata: "Automata"
        case .chladni: "Chladni"
        case .leaves: "Leaves"
        case .warp: "Warp Speed"
        case .ascii: "ASCII Art"
        case .polyhedra: "Polyhedra"
        case .maze: "10 PRINT"
        case .dither: "Dither"
        case .pipes: "Pipes"
        case .pebbles: "Pebbles"
        case .macpattern: "Desktop Pattern"
        case .pinstripe: "Platinum Pinstripes"
        case .clouds: "Clouds"
        case .azul: "Azul"
        case .winpattern: "Windows Pattern"
        case .boing: "Boing Ball"
        case .rain: "Digital Rain"
        case .solid: "Solid"
        }
    }

    var summary: String {
        switch self {
        case .glow: "Diagonal wash lit by soft accent glows"
        case .mesh: "Smooth blend of the palette's key colors"
        case .waves: "Layered sine waves rising from the bottom"
        case .ridges: "Mountain ridges fading into a sky, with a sun"
        case .bokeh: "Out-of-focus light discs in palette hues"
        case .lowpoly: "Faceted triangles over a color field"
        case .topographic: "Contour lines of a noise landscape"
        case .sunset: "Striped sun over a perspective grid"
        case .arcs: "Seventies rainbow bands from a corner"
        case .pulsar: "Stacked line plots peaking in the middle, after the Unknown Pleasures cover"
        case .guilloche: "Hairline rosettes braided from sine-modulated rings, like a banknote"
        case .sashiko: "Hitomezashi running stitches, with the shapes they close off tinted"
        case .attractor: "A Clifford strange attractor, shaded by how often each spot is visited"
        case .bauhaus: "Tiles of quarter circles, half circles, triangles, lenses and stripes"
        case .destijl: "Mondrian's rectangles: heavy rules and a few red, blue and yellow panels"
        case .truchet: "Quarter-circle tiles in random turns, two-colored so regions alternate"
        case .terrazzo: "Stone chips of every size scattered over a mottled ground"
        case .circles: "Circles grown until they touch: solid, ringed and outlined"
        case .isometric: "Isometric blocks stacked to a noise heightmap, shaded on three faces"
        case .penrose: "Penrose's thin and thick rhombs, a tiling that never repeats"
        case .flow: "Evenly spaced streamlines through a noise field, tapering where they crowd, around a disc"
        case .lens: "Tilted bands and a sun bent around a black hole by a gravitational lens"
        case .papercut: "Layered paper sheets with soft shadows, parting around a sun"
        case .automata: "Panels of elementary cellular automata, each running its own Wolfram rule"
        case .chladni: "Sand gathering on the still lines of a vibrating plate"
        case .leaves: "Haiku's Leaves screen saver: gradient leaves piling up on the desktop"
        case .warp: "Star streaks at warp speed, after OS/2 Warp"
        case .ascii: "Terminal-character art: donut.c's lit torus, the Mandelbrot set or aafire's flames"
        case .polyhedra: "NeXTSTEP BackSpace's Polyhedra: a regular solid in perspective on black"
        case .maze: "The Commodore 64's one-line maze, its sealed-off rooms tinted"
        case .dither: "A banded planet in four tones, Bayer-dithered into chunky pixels"
        case .pipes: "Shiny pipes wandering a 3D grid, after the Windows NT screen saver"
        case .pebbles: "The classic Mac desktop tile: a soft rippled weave in pixels, recolored from the desktop color"
        case .macpattern: "A one-bit 8×8 tile from the Desktop Patterns control panel, in two tones"
        case .pinstripe: "Platinum's thin horizontal pinstripes, easing in tone down the screen"
        case .clouds: "Windows 95's cloudy sky, in chunky pixels dithered down to 15-bit color"
        case .azul: "Twisting ribbons of light over deep blue, after Windows XP's Azul"
        case .winpattern: "A one-bit 8×8 desktop pattern from Windows 3.0 and 95, drawn over the desktop color"
        case .boing: "The Amiga Boing Ball: a checkered sphere before a grid, in 12-bit color"
        case .rain: "QNX Photon's screen saver: columns of glyphs raining down the screen"
        case .solid: "Just the background color"
        }
    }

    var icon: String {
        switch self {
        case .glow: "light.max"
        case .mesh: "circle.hexagongrid"
        case .waves: "water.waves"
        case .ridges: "mountain.2"
        case .bokeh: "circle.circle"
        case .lowpoly: "triangle"
        case .topographic: "map"
        case .sunset: "sunset"
        case .arcs: "rainbow"
        case .pulsar: "waveform.path.ecg"
        case .guilloche: "seal"
        case .sashiko: "square.dashed"
        case .attractor: "hurricane"
        case .bauhaus: "square.on.circle"
        case .destijl: "square.split.bottomrightquarter"
        case .truchet: "point.topleft.down.curvedto.point.bottomright.up"
        case .terrazzo: "aqi.medium"
        case .circles: "circles.hexagonpath"
        case .isometric: "square.stack.3d.up"
        case .penrose: "rhombus"
        case .flow: "wind"
        case .lens: "camera.aperture"
        case .papercut: "square.3.layers.3d.down.right"
        case .automata: "rectangle.split.3x3"
        case .chladni: "waveform.path"
        case .leaves: "leaf"
        case .warp: "sparkles"
        case .ascii: "terminal"
        case .polyhedra: "cube.transparent"
        case .maze: "chevron.left.forwardslash.chevron.right"
        case .dither: "checkerboard.rectangle"
        case .pipes: "pipe.and.drop"
        case .pebbles: "square.grid.3x3.fill"
        case .macpattern: "checkerboard.rectangle"
        case .pinstripe: "line.3.horizontal"
        case .clouds: "cloud"
        case .azul: "light.ribbon"
        case .winpattern: "square.grid.4x3.fill"
        case .boing: "circle.grid.cross"
        case .rain: "text.alignleft"
        case .solid: "square.fill"
        }
    }

    /// A style name from config (`auto` resolves per theme). Nil if unknown.
    static func resolve(_ name: String, slug: String) -> WallpaperStyle? {
        if name.lowercased() == automatic {
            let hash = StableHash.of(slug), slots = UInt64(automaticSlots.count)
            // A theme that lands on an empty slot picks again, from the styles left.
            return automaticSlots[Int(hash % slots)] ?? varied[Int(hash / slots % UInt64(varied.count))]
        }
        return WallpaperStyle(rawValue: name.lowercased())
    }
}

/// Everything that determines a generated wallpaper besides the palette.
struct WallpaperChoice: Sendable, Equatable {
    let style: WallpaperStyle
    /// Variation within the style (positions, shapes). Same seed, same picture.
    let seed: UInt64
    /// Fine film grain texture on top.
    let grain: Bool
}

// MARK: - Deterministic randomness

enum StableHash {
    /// FNV-1a — stable across launches, unlike `Hasher`.
    static func of(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return hash
    }
}

/// SplitMix64: tiny, fast, and reproducible from a seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func unit() -> Double {
        Double.random(in: 0 ..< 1, using: &self)
    }

    mutating func between(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    /// An integer in `0 ..< count`.
    mutating func int(below count: Int) -> Int {
        min(Int(unit() * Double(count)), count - 1)
    }

    mutating func pick<Element>(_ elements: [Element]) -> Element {
        elements[int(below: elements.count)]
    }
}

/// Smooth 2D value noise with fractal octaves, in `0...1`.
struct ValueNoise: Sendable {
    let seed: UInt64

    func value(_ x: Double, _ y: Double) -> Double {
        let x0 = floor(x)
        let y0 = floor(y)
        let fx = smooth(x - x0)
        let fy = smooth(y - y0)
        let ix = Int64(x0)
        let iy = Int64(y0)
        let top = lattice(ix, iy) + (lattice(ix + 1, iy) - lattice(ix, iy)) * fx
        let bottom = lattice(ix, iy + 1) + (lattice(ix + 1, iy + 1) - lattice(ix, iy + 1)) * fx
        return top + (bottom - top) * fy
    }

    func fractal(_ x: Double, _ y: Double, octaves: Int = 4) -> Double {
        var total = 0.0
        var amplitude = 0.5
        var frequency = 1.0
        var norm = 0.0
        for _ in 0 ..< octaves {
            total += value(x * frequency, y * frequency) * amplitude
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2.03
        }
        return total / norm
    }

    private func smooth(_ value: Double) -> Double {
        value * value * value * (value * (value * 6 - 15) + 10)
    }

    private func lattice(_ x: Int64, _ y: Int64) -> Double {
        var generator = SeededGenerator(
            seed: seed ^ (UInt64(bitPattern: x) &* 0x9E37_79B9) ^ (UInt64(bitPattern: y) &* 0x85EB_CA77_C2B2_AE63)
        )
        return generator.unit()
    }
}

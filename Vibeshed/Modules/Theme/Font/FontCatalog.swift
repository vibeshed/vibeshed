import CoreText
import Foundation

/// A coding font `theme/switchFont` knows, by the family names it's installed under:
/// as published, and patched by Nerd Fonts (or by the font itself) with prompt and
/// file-type icons.
struct FontDefinition: Sendable, Equatable {
    let name: String
    /// Plain family names, preferred first.
    let families: [String]
    /// Icon-patched families, single-width ("Mono") variants first.
    let nerdFamilies: [String]
    /// Families cut for terminals (Iosevka Term) and their patched variants.
    let terminalFamilies: [String]
    let terminalNerdFamilies: [String]
    let summary: String
    let keywords: [String]

    /// `nerd`/`terminalNerd` are Nerd Fonts' base names ("JetBrainsMono" for JetBrains Mono);
    /// `nerdFamilies` lists patched families named some other way ("Maple Mono NF").
    init(
        _ name: String,
        families: [String]? = nil,
        nerd: [String] = [],
        nerdFamilies: [String] = [],
        terminal: [String] = [],
        terminalNerd: [String] = [],
        summary: String,
        keywords: [String] = []
    ) {
        self.name = name
        self.families = families ?? [name]
        self.nerdFamilies = nerd.flatMap(Self.nerdVariants) + nerdFamilies
        self.terminalFamilies = terminal
        self.terminalNerdFamilies = terminalNerd.flatMap(Self.nerdVariants)
        self.summary = summary
        self.keywords = keywords
    }

    /// Nerd Fonts' family names: v3's, then v2's Windows-compatible short ones.
    static func nerdVariants(_ base: String) -> [String] {
        ["\(base) Nerd Font Mono", "\(base) Nerd Font", "\(base) NFM", "\(base) NF"]
    }

    /// Terminals prefer icon-patched, single-width faces: shell prompts and `ls` icons
    /// draw from them, and wide icons would overlap the next cell.
    var terminalCandidates: [String] {
        terminalNerdFamilies + terminalFamilies + nerdFamilies + families
    }

    /// Editors prefer the font as published; a patched copy is the fallback.
    var editorCandidates: [String] {
        let isSingleWidth = { (family: String) in family.hasSuffix(" Mono") || family.hasSuffix(" NFM") }
        return families + nerdFamilies.filter { !isSingleWidth($0) } + nerdFamilies.filter(isSingleWidth)
            + terminalFamilies + terminalNerdFamilies
    }

    /// The font as installed here; nil when none of its families is.
    func resolve(installed: Set<String>) -> ResolvedFont? {
        guard let editor = editorCandidates.first(where: installed.contains),
              let terminal = terminalCandidates.first(where: installed.contains)
        else { return nil }
        var families: [String] = []
        for family in editorCandidates + terminalCandidates where installed.contains(family) {
            if !families.contains(family) { families.append(family) }
        }
        return ResolvedFont(
            name: name, slug: ResolvedTheme.slug(for: name), editorFamily: editor, terminalFamily: terminal,
            families: families, summary: summary, keywords: keywords
        )
    }
}

/// A font that's installed, with the family each kind of app gets.
struct ResolvedFont: Sendable, Equatable, Codable {
    let name: String
    let slug: String
    /// For editors (VS Code, Zed, JetBrains).
    let editorFamily: String
    /// For terminals (iTerm, Ghostty, Terminal) and editors' terminal panels.
    let terminalFamily: String
    /// Every installed family of the font, for recognizing it in an app's settings.
    let families: [String]
    let summary: String
    var keywords: [String] = []

    /// Whether terminals get an icon-patched family.
    var hasIcons: Bool {
        terminalFamily.contains("Nerd Font") || terminalFamily.hasSuffix(" NF") || terminalFamily.hasSuffix(" NFM")
    }
}

enum FontCatalog {
    /// The installed fonts to offer, by name: the curated ones plus config's `fonts:`
    /// (which replace a curated font of the same name).
    static func fonts(config: ThemeConfig, installed: Set<String> = installedFamilies()) -> [ResolvedFont] {
        let configured = config.fonts.map { FontDefinition($0, summary: "From config") }
        var bySlug: [String: ResolvedFont] = [:]
        for definition in curated + configured {
            if let font = definition.resolve(installed: installed) { bySlug[font.slug] = font }
        }
        return bySlug.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The font in use: the one `theme/switchFont` applied last, else the first one an app
    /// is set to (in `targets` order).
    static func current(among fonts: [ResolvedFont], targets: [any FontTarget], config: ThemeConfig) -> ResolvedFont? {
        if let committed = CommittedFont.current?.slug, let font = fonts.first(where: { $0.slug == committed }) {
            return font
        }
        for family in targets.lazy.compactMap({ $0.currentFamily(config: config) }) {
            if let font = fonts.first(where: { $0.families.contains(family) }) { return font }
        }
        return nil
    }

    /// Every font family registered with the system, fonts installed since launch included
    /// once fontd has them (see `FontActivation` for when it doesn't on its own).
    static func installedFamilies() -> Set<String> {
        Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
    }

    /// Popular coding fonts. Only installed ones are listed, so entries cost nothing.
    static let curated: [FontDefinition] = [
        FontDefinition("SF Mono", nerd: ["SFMono"], summary: "Apple · the system monospace"),
        FontDefinition("Menlo", summary: "Apple · Terminal's classic"),
        FontDefinition("Monaco", summary: "Apple · the original Mac monospace"),
        FontDefinition("JetBrains Mono", nerd: ["JetBrainsMono"], summary: "JetBrains · ligatures"),
        FontDefinition("JetBrains Mono NL", nerd: ["JetBrainsMonoNL"], summary: "JetBrains · without ligatures"),
        FontDefinition("Fira Code", nerd: ["FiraCode"], summary: "Mozilla's Fira Mono · ligatures"),
        FontDefinition("Fira Mono", nerd: ["FiraMono"], summary: "Mozilla"),
        FontDefinition("Cascadia Code", nerd: ["CaskaydiaCove"], summary: "Microsoft · ligatures, cursive italics"),
        FontDefinition("Cascadia Mono", nerd: ["CaskaydiaMono"], summary: "Microsoft · without ligatures"),
        FontDefinition("Source Code Pro", nerd: ["SauceCodePro"], summary: "Adobe"),
        FontDefinition("IBM Plex Mono", nerd: ["BlexMono"], summary: "IBM"),
        FontDefinition("Hack", nerd: ["Hack"], summary: "Source Foundry · DejaVu-based"),
        FontDefinition(
            "Iosevka", nerd: ["Iosevka"], terminal: ["Iosevka Term"], terminalNerd: ["IosevkaTerm"],
            summary: "Narrow and highly configurable · ligatures"
        ),
        FontDefinition(
            "Meslo", families: ["Meslo LG M", "Meslo LG S", "Meslo LG L"], nerd: ["MesloLGM", "MesloLGS", "MesloLGL"],
            nerdFamilies: ["MesloLGS NF"], summary: "Menlo, retuned · powerlevel10k's pick"
        ),
        FontDefinition("Geist Mono", nerd: ["GeistMono"], summary: "Vercel"),
        FontDefinition(
            "Commit Mono", families: ["CommitMono", "Commit Mono"], nerd: ["CommitMono"],
            summary: "Neutral, with smart kerning"
        ),
        monaspace("Neon", nerd: "Ne", summary: "GitHub · neo-grotesque, texture healing"),
        monaspace("Argon", nerd: "Ar", summary: "GitHub · humanist, texture healing"),
        monaspace("Xenon", nerd: "Xe", summary: "GitHub · slab serif, texture healing"),
        monaspace("Radon", nerd: "Rn", summary: "GitHub · handwriting, texture healing"),
        monaspace("Krypton", nerd: "Kr", summary: "GitHub · mechanical, texture healing"),
        FontDefinition("Victor Mono", nerd: ["VictorMono"], summary: "Cursive italics · ligatures"),
        FontDefinition("Maple Mono", nerdFamilies: ["Maple Mono NF"], summary: "Rounded · ligatures"),
        FontDefinition("Ubuntu Mono", nerd: ["UbuntuMono"], summary: "Canonical"),
        FontDefinition("Ubuntu Sans Mono", nerd: ["UbuntuSansMono"], summary: "Canonical"),
        FontDefinition("Roboto Mono", nerd: ["RobotoMono"], summary: "Google"),
        FontDefinition("Noto Sans Mono", nerd: ["NotoSansM"], summary: "Google"),
        FontDefinition("Inconsolata", nerd: ["Inconsolata"], summary: "Raph Levien"),
        FontDefinition(
            "Intel One Mono", families: ["Intel One Mono", "IntelOne Mono"], nerd: ["IntoneMono"],
            summary: "Intel · made for low-vision readers"
        ),
        FontDefinition("Space Mono", nerd: ["SpaceMono"], summary: "Colophon · retro-futuristic"),
        FontDefinition("DejaVu Sans Mono", nerd: ["DejaVuSansM"], summary: "Bitstream Vera-based"),
        FontDefinition("Hasklig", nerd: ["Hasklug"], summary: "Source Code Pro · ligatures"),
        FontDefinition("Fantasque Sans Mono", nerd: ["FantasqueSansM"], summary: "Handwritten feel"),
        FontDefinition("Martian Mono", nerd: ["MartianMono"], summary: "Evil Martians · wide"),
        FontDefinition("Lilex", nerd: ["Lilex"], summary: "IBM Plex-based · ligatures"),
        FontDefinition("0xProto", nerd: ["0xProto"], summary: "Distinct glyphs · ligatures"),
        FontDefinition(
            "Recursive Mono", families: ["Rec Mono Linear", "Rec Mono Casual"],
            nerd: ["RecMonoLinear", "RecMonoCasual"], summary: "Arrow Type · linear or casual"
        ),
        FontDefinition(
            "Atkinson Hyperlegible Mono", nerd: ["AtkynsonMono"], summary: "Braille Institute · built for legibility"
        ),
        FontDefinition("Departure Mono", nerd: ["DepartureMono"], summary: "Pixel font"),
        FontDefinition("Zed Mono", nerd: ["ZedMono"], summary: "Zed · Iosevka-based"),
        FontDefinition(
            "Berkeley Mono", families: ["Berkeley Mono", "TX-02", "Berkeley Mono Variable"], nerd: ["BerkeleyMono"],
            summary: "US Graphics · commercial"
        ),
        FontDefinition(
            "Operator Mono", families: ["Operator Mono", "Operator Mono SSm"], summary: "Hoefler&Co. · cursive italics"
        ),
        FontDefinition("Input Mono", families: ["Input Mono", "InputMono"], summary: "DJR · designed for code"),
        FontDefinition("Comic Mono", summary: "Comic Sans, monospaced"),
        FontDefinition("Comic Shanns Mono", nerd: ["ComicShannsMono"], summary: "Comic Sans-inspired"),
        FontDefinition("Go Mono", nerd: ["GoMono"], summary: "The Go project · slab serif"),
        FontDefinition("Anonymous Pro", nerd: ["AnonymicePro"], summary: "Mark Simonson"),
        FontDefinition("mononoki", nerd: ["Mononoki"], summary: "Designed for code"),
        FontDefinition("Monoid", nerd: ["Monoid"], summary: "Narrow · ligatures"),
        FontDefinition("Cousine", nerd: ["Cousine"], summary: "ChromeOS · Courier New's metrics"),
    ]

    private static func monaspace(_ variant: String, nerd: String, summary: String) -> FontDefinition {
        let family = "Monaspace \(variant)"
        return FontDefinition(
            family, families: [family, "\(family) Var", "\(family) Frozen"], nerd: ["Monaspice\(nerd)"],
            summary: summary, keywords: ["monaspace"]
        )
    }
}

/// The font last applied with `theme/switchFont`. Profiles the theme rebuilds (iTerm's,
/// Terminal's) carry it, so switching themes keeps the font.
enum CommittedFont {
    private static let defaultsKey = "theme.font"

    static var current: ResolvedFont? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ResolvedFont.self, from: data)
    }

    static func save(_ font: ResolvedFont) {
        guard let data = try? JSONEncoder().encode(font) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Picking faces by weight, for apps that take a concrete face (iTerm, Terminal) rather
/// than a family.
enum FontFaces {
    struct Face: Equatable {
        let postScriptName: String
        let weight: CGFloat
        let width: CGFloat
        /// A named instance of a variable font, which some apps handle less well than
        /// a static face.
        let isVariable: Bool
    }

    /// `family`'s upright faces.
    static func faces(of family: String) -> [Face] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
        return matches.compactMap { match in
            guard let name = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String,
                  CTFontDescriptorCopyAttribute(match, kCTFontFamilyNameAttribute) as? String == family
            else { return nil }
            let traits = CTFontDescriptorCopyAttribute(match, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let symbolic = (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0
            let slant = (traits[kCTFontSlantTrait] as? CGFloat) ?? 0
            guard symbolic & CTFontSymbolicTraits.traitItalic.rawValue == 0, abs(slant) < 0.01 else { return nil }
            return Face(
                postScriptName: name,
                weight: (traits[kCTFontWeightTrait] as? CGFloat) ?? 0,
                width: (traits[kCTFontWidthTrait] as? CGFloat) ?? 0,
                isVariable: CTFontDescriptorCopyAttribute(match, kCTFontVariationAttribute) != nil
            )
        }
    }

    /// The PostScript name of `family`'s upright, normal-width face nearest in weight to
    /// the face named `reference` (regular when there's none) — so a Medium terminal font
    /// stays Medium where the new family has one. Static faces win ties.
    static func face(of family: String, like reference: String?) -> String? {
        let target = reference.flatMap(weight(ofFace:)) ?? 0
        let rank = { (face: Face) in
            (abs(face.width), abs(face.weight - target), face.isVariable ? 1 : 0, face.weight)
        }
        return faces(of: family).min { rank($0) < rank($1) }?.postScriptName
    }

    /// The family of an installed face.
    static func family(ofFace postScriptName: String) -> String? {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName else { return nil }
        return CTFontCopyFamilyName(font) as String
    }

    /// The weight trait (-1…1, regular 0) of an installed face.
    static func weight(ofFace postScriptName: String) -> CGFloat? {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName else { return nil }
        let traits = CTFontCopyTraits(font) as? [CFString: Any] ?? [:]
        return (traits[kCTFontWeightTrait] as? CGFloat) ?? 0
    }
}

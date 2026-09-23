import AppKit

extension NSColor {
    /// Using a color list let's us get localized names.
    private static let appleColorList: NSColorList? = NSColorList(named: "Apple")

    convenience init?(named name: String) {
        guard let colorList = Self.appleColorList,
              let color = colorList.color(withKey: name.capitalized) else {
            return nil
        }
        guard let components = color.usingColorSpace(.sRGB) else {
            return nil
        }
        self.init(
            red: components.redComponent,
            green: components.greenComponent,
            blue: components.blueComponent,
            alpha: components.alphaComponent
        )
    }

    static var colorNames: [String] {
        appleColorList?.allKeys.map { $0.lowercased() } ?? []
    }

    /// Calculates the perceptual distance to another color in RGB space.
    func distance(to other: NSColor) -> Double {
        guard let a = self.usingColorSpace(.sRGB),
              let b = other.usingColorSpace(.sRGB) else { return .infinity }

        let dr = a.redComponent - b.redComponent
        let dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent - b.blueComponent

        // Weighted Euclidean distance (human eye is more sensitive to green)
        return sqrt(2 * dr * dr + 4 * dg * dg + 3 * db * db)
    }
}

nonisolated extension NSColor {
    var isLightColor: Bool {
        return self.luminance > 0.5
    }

    var luminance: Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        // getRed:green:blue:alpha requires sRGB space
        guard let rgb = self.usingColorSpace(.sRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    func darken(by amount: CGFloat) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // Catalog/system colors must be resolved before extracting components.
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: s,
            brightness: min(b * (1 - amount), 1),
            alpha: a
        )
    }
}

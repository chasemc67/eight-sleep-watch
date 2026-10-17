import SwiftUI

/// Eight Sleep's own App Store temperature screenshot (retrieved 2026-10-16):
/// https://apps.apple.com/us/app/eight-sleep/id1086913845
/// https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/ed/9b/7e/ed9b7e1c-d54b-040d-a0d0-13bae05ced05/2_APP_IPHONE_67_2.jpg/1290x2796bb.jpg
/// Pillow RGB medians of interior colored glyph pixels: +1 at (910,1390)-(960,1450),
/// R>175,R>1.3G,R>1.05B => (198,115,140); -4 at (620,1390)-(665,1450),
/// B>190,B>1.4R,B>1.1G => (56,88,208). JPEG samples, not claimed brand tokens.
/// Cross-check: https://www.eightsleep.com CSS uses #4158ee as its website accent;
/// the temperature glyphs above are the source for the app-specific warm/cool pair.
/// Navy/card colors reproduce Grok's reference UI, rounded to 8-bit RGB.
enum Theme {
    static let warm = color(0xC6738C)
    static let cool = color(0x3858D0)
    static let background = color(0x0D1217)
    static let card = color(0x1F262E)
    static let muted = color(0xA0A7B2)
    static let neutral = Color.white

    static func levelColor(_ raw: Int?) -> Color {
        guard let raw, raw != 0 else { return neutral }
        return raw > 0 ? warm : cool
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

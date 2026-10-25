import SwiftUI
import UIKit

enum SoftThemePreset: String, CaseIterable, Codable, Identifiable {
    case warmOat = "warm_oat"
    case softSage = "soft_sage"
    case mistyLavender = "misty_lavender"
    case sereneBlue = "serene_blue"
    case blushRose = "blush_rose"
    case minimalAlabaster = "minimal_alabaster"
    case warmNight = "warm_night"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .warmOat: return "暖米燕麦"
        case .softSage: return "抹茶鼠尾草"
        case .mistyLavender: return "迷雾薰衣草"
        case .sereneBlue: return "晨雾海盐"
        case .blushRose: return "樱花粉霞"
        case .minimalAlabaster: return "云母浅灰"
        case .warmNight: return "静谧暖夜"
        }
    }

    var subtitle: String {
        switch self {
        case .warmOat: return "温润护眼纸感"
        case .softSage: return "清新森系柔绿"
        case .mistyLavender: return "淡雅灰紫微光"
        case .sereneBlue: return "清透海盐雾蓝"
        case .blushRose: return "柔和豆沙浅粉"
        case .minimalAlabaster: return "极简现代暖白"
        case .warmNight: return "柔和低对比暗色"
        }
    }

    var backgroundHex: String {
        switch self {
        case .warmOat: return "F6F1E7"
        case .softSage: return "EDF4EF"
        case .mistyLavender: return "F2EFF8"
        case .sereneBlue: return "EDF3F8"
        case .blushRose: return "F8EFF1"
        case .minimalAlabaster: return "F4F5F7"
        case .warmNight: return "1B1D22"
        }
    }

    var accentHex: String {
        switch self {
        case .warmOat: return "9C6B3B"
        case .softSage: return "3D7A5A"
        case .mistyLavender: return "6B5B95"
        case .sereneBlue: return "3B6E96"
        case .blushRose: return "A6566A"
        case .minimalAlabaster: return "435585"
        case .warmNight: return "7C9BFF"
        }
    }
}

struct AppThemePalette: Equatable {
    let backgroundHex: String
    let accentHex: String
    let background: Color
    let cardBackground: Color
    let elevatedBackground: Color
    let userMessageBackground: Color
    let accent: Color
    let primaryText: Color
    let secondaryText: Color
    let mutedText: Color
    let border: Color
    let isDark: Bool

    var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    static func make(backgroundHex: String, accentHex: String) -> AppThemePalette {
        let bg = Color.rgbComponents(from: backgroundHex)
        let ac = Color.rgbComponents(from: accentHex)
        let luminance = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
        let isDark = luminance < 0.42

        let background = Color(.sRGB, red: bg.r, green: bg.g, blue: bg.b, opacity: 1.0)
        let accent = Color(.sRGB, red: ac.r, green: ac.g, blue: ac.b, opacity: 1.0)

        if isDark {
            let cardR = min(1.0, bg.r + (1.0 - bg.r) * 0.065)
            let cardG = min(1.0, bg.g + (1.0 - bg.g) * 0.065)
            let cardB = min(1.0, bg.b + (1.0 - bg.b) * 0.065)

            let elevR = min(1.0, bg.r + (1.0 - bg.r) * 0.12)
            let elevG = min(1.0, bg.g + (1.0 - bg.g) * 0.12)
            let elevB = min(1.0, bg.b + (1.0 - bg.b) * 0.12)

            let userR = cardR * 0.82 + ac.r * 0.18
            let userG = cardG * 0.82 + ac.g * 0.18
            let userB = cardB * 0.82 + ac.b * 0.18

            return AppThemePalette(
                backgroundHex: backgroundHex,
                accentHex: accentHex,
                background: background,
                cardBackground: Color(.sRGB, red: cardR, green: cardG, blue: cardB, opacity: 1.0),
                elevatedBackground: Color(.sRGB, red: elevR, green: elevG, blue: elevB, opacity: 1.0),
                userMessageBackground: Color(.sRGB, red: userR, green: userG, blue: userB, opacity: 1.0),
                accent: accent,
                primaryText: Color(.sRGB, red: 0.93, green: 0.94, blue: 0.96, opacity: 1.0),
                secondaryText: Color(.sRGB, red: 0.66, green: 0.69, blue: 0.75, opacity: 1.0),
                mutedText: Color(.sRGB, red: 0.48, green: 0.51, blue: 0.57, opacity: 1.0),
                border: Color.white.opacity(0.08),
                isDark: true
            )
        } else {
            let cardR = bg.r * 0.35 + 1.0 * 0.65
            let cardG = bg.g * 0.35 + 1.0 * 0.65
            let cardB = bg.b * 0.35 + 1.0 * 0.65

            let elevR = max(0.0, bg.r * 0.95)
            let elevG = max(0.0, bg.g * 0.95)
            let elevB = max(0.0, bg.b * 0.95)

            let userR = cardR * 0.88 + ac.r * 0.12
            let userG = cardG * 0.88 + ac.g * 0.12
            let userB = cardB * 0.88 + ac.b * 0.12

            let borderR = max(0.0, bg.r * 0.86)
            let borderG = max(0.0, bg.g * 0.86)
            let borderB = max(0.0, bg.b * 0.86)

            return AppThemePalette(
                backgroundHex: backgroundHex,
                accentHex: accentHex,
                background: background,
                cardBackground: Color(.sRGB, red: cardR, green: cardG, blue: cardB, opacity: 1.0),
                elevatedBackground: Color(.sRGB, red: elevR, green: elevG, blue: elevB, opacity: 1.0),
                userMessageBackground: Color(.sRGB, red: userR, green: userG, blue: userB, opacity: 1.0),
                accent: accent,
                primaryText: Color(.sRGB, red: 0.15, green: 0.17, blue: 0.20, opacity: 1.0),
                secondaryText: Color(.sRGB, red: 0.42, green: 0.45, blue: 0.50, opacity: 1.0),
                mutedText: Color(.sRGB, red: 0.56, green: 0.59, blue: 0.64, opacity: 1.0),
                border: Color(.sRGB, red: borderR, green: borderG, blue: borderB, opacity: 0.7),
                isDark: false
            )
        }
    }
}

extension Color {
    init(hex: String) {
        let comp = Color.rgbComponents(from: hex)
        self.init(.sRGB, red: comp.r, green: comp.g, blue: comp.b, opacity: 1.0)
    }

    func toHex() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let ri = max(0, min(255, Int(round(r * 255))))
            let gi = max(0, min(255, Int(round(g * 255))))
            let bi = max(0, min(255, Int(round(b * 255))))
            return String(format: "%02X%02X%02X", ri, gi, bi)
        }
        return "F6F1E7"
    }

    static func rgbComponents(from hex: String) -> (r: Double, g: Double, b: Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6, 8:
            (r, g, b) = (int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (246, 241, 231)
        }
        return (Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0)
    }
}

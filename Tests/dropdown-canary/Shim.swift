// Canary-only palette. COSPalette lives in Views.swift, which drags in the whole app; the canary compiles the REAL
// Sources/COSBrand.swift (the component under test) and stubs only these colours, copied from Views.swift.
import AppKit
import SwiftUI
func adaptiveNSColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
}
enum COSInk {
    static let panelNS = adaptiveNSColor(light: NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1), dark: NSColor(red: 0.09, green: 0.07, blue: 0.05, alpha: 1))
    static let cardNS = adaptiveNSColor(light: .white, dark: NSColor(red: 0.15, green: 0.115, blue: 0.085, alpha: 1))
    static let lineNS = adaptiveNSColor(light: NSColor(red: 0.45, green: 0.34, blue: 0.16, alpha: 0.20), dark: NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 0.16))
    static let accentNS = adaptiveNSColor(light: NSColor(red: 0.537, green: 0.400, blue: 0.176, alpha: 1), dark: NSColor(red: 0.788, green: 0.659, blue: 0.431, alpha: 1))
    static let dangerNS = adaptiveNSColor(light: NSColor(red: 0.647, green: 0.278, blue: 0.196, alpha: 1), dark: NSColor(red: 0.910, green: 0.643, blue: 0.580, alpha: 1))
    static let mutedNS = adaptiveNSColor(light: NSColor(red: 0.455, green: 0.447, blue: 0.427, alpha: 1), dark: NSColor(red: 0.733, green: 0.682, blue: 0.604, alpha: 1))
    static let raisedNS = adaptiveNSColor(light: NSColor(red: 0.933, green: 0.910, blue: 0.867, alpha: 1), dark: NSColor(red: 0.188, green: 0.153, blue: 0.122, alpha: 1))
}
enum COSPalette {
    static let ink = Color(red: 0.12, green: 0.09, blue: 0.07)
    static let panel = Color(nsColor: COSInk.panelNS)
    static let card = Color(nsColor: COSInk.cardNS)
    static let line = Color(nsColor: COSInk.lineNS)
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let gold = Color(red: 0.79, green: 0.66, blue: 0.43)
    static let amber = Color(red: 0.79, green: 0.50, blue: 0.27)
    static let green = Color(red: 0.20, green: 0.58, blue: 0.34)
    static let accent = Color(nsColor: COSInk.accentNS)
    static let danger = Color(nsColor: COSInk.dangerNS)
    static let muted = Color(nsColor: COSInk.mutedNS)
    static let raised = Color(nsColor: COSInk.raisedNS)
}

import SwiftUI

// Canary-only. COSPalette lives in Views.swift, which drags in the whole app;
// the canary compiles the REAL Sources/COSConfirm.swift and Sources/COSBrand.swift
// and stubs only the palette. The component under test is the shipped one, not a
// copy of it -- a canary that re-implements its subject proves nothing.
enum COSPalette {
    static let ink = Color(red: 0.12, green: 0.09, blue: 0.07)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let amber = Color(red: 0.79, green: 0.50, blue: 0.27)
    static let gold = Color(red: 0.79, green: 0.66, blue: 0.43)
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let green = Color(red: 0.20, green: 0.58, blue: 0.34)
}

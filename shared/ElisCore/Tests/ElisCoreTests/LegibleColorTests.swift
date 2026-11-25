import Testing
@testable import ElisCore

struct LegibleColorTests {
    private let white = RGBA(r: 1, g: 1, b: 1)
    private let black = RGBA(r: 0, g: 0, b: 0)

    private func contrast(_ c: RGBA, over bg: RGBA) -> Double {
        let a = RGBA.luminance(RGBA.composite(c, over: bg))
        let b = RGBA.luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func legibleOnKeepsAColorThatAlreadyPasses() {
        let color = RGBA(r: 0, g: 0, b: 0.5)
        #expect(legibleOn(color, under: [white], text: black) == color)
    }

    @Test func legibleOnPushesYellowOffAYellowBandAndAWhiteSidebar() {
        let yellow = RGBA(r: 1, g: 0.8, b: 0)
        let band = RGBA.composite(RGBA(r: 1, g: 0.8, b: 0, a: 0.2), over: white)
        let result = legibleOn(yellow, under: [white, band], text: RGBA(r: 0.1, g: 0.1, b: 0.1))
        #expect(result != yellow)
        for bg in [white, band] { #expect(contrast(result, over: bg) >= 4.5) }
    }

    @Test func legibleOnKeepsAlpha() {
        let color = RGBA(r: 0.2, g: 0.2, b: 0.2, a: 0.55)
        let bg = RGBA(r: 0.95, g: 0.95, b: 0.95)
        let result = legibleOn(color, under: [bg], text: black)
        #expect(result.a == 0.55)
        #expect(contrast(result, over: bg) >= 4.5)
    }

    @Test func legibleOnFallsBackToTheTextColorWhenNothingPasses() {
        let gray = RGBA(r: 0.5, g: 0.5, b: 0.5)
        let color = RGBA(r: 1, g: 0, b: 0)
        let result = legibleOn(color, under: [gray], text: gray)
        #expect(result == gray)
        #expect(result != color)
    }

    @Test func legibleOnMustPassEveryBackdrop() {
        // No red shade toward black reaches 4.5:1 on both white and black.
        #expect(legibleOn(RGBA(r: 1, g: 0, b: 0), under: [white, black], text: black) == black)
    }

    @Test func luminanceMatchesWCAGAnchors() {
        #expect(RGBA.luminance(white) == 1)
        #expect(RGBA.luminance(black) == 0)
        #expect(abs(RGBA.luminance(RGBA(r: 1, g: 0, b: 0)) - 0.2126) < 1e-9)
    }
}

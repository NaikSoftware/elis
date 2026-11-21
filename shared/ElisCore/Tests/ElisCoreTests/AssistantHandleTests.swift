import Testing
@testable import ElisCore

struct AssistantHandleTests {
    @Test func cyrillicNameKeepsTwoWordsAndShortensLongOnes() {
        #expect(AssistantHandle.assign([("a", "Міграція Linux-версії за планом")]) == ["a": "mihr-linux"])
    }

    @Test func latinNameDropsStopwords() {
        #expect(AssistantHandle.assign([("a", "fix the sidebar filter")]) == ["a": "fix-side"])
    }

    @Test func duplicatesGetSuffixesInOrder() {
        #expect(AssistantHandle.assign([("a", "logcat"), ("b", "logcat")]) == ["a": "logcat", "b": "logcat-2"])
    }

    @Test func emptyTransliterationFallsBackToId() {
        #expect(AssistantHandle.assign([("3fa9c1d2-0000", "🚀 ~")]) == ["3fa9c1d2-0000": "s-3fa9"])
    }

    @Test func handlesAreCappedAndClean() {
        let handle = AssistantHandle.assign([("a", "superlongword anotherlongword")])["a"]!
        #expect(handle.count <= 12)
        #expect(handle.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
        #expect(!handle.hasSuffix("-"))
    }

    @Test func apostrophesAndSoftSignsStayInWordAndExtraCyrillicMaps() {
        #expect(AssistantHandle.assign([("a", "пам’ять об'єкт")]) == ["a": "pamiat-obiek"])
        #expect(AssistantHandle.assign([("a", "щілина ёж мышь эхо")]) == ["a": "shch-ezh"])
    }

    @Test func ukrainianStopwordsDroppedWithoutAffectingLatinWords() {
        #expect(AssistantHandle.assign([("a", "Робота з файлами"), ("b", "do work")]) == ["a": "robota-fail", "b": "do-work"])
    }

    @Test func collidingLongHandlesStayWithinCap() {
        let out = AssistantHandle.assign([
            ("a", "abcdef ghijkl"),
            ("b", "abcdef ghijkl"),
            ("c", "abcdef ghijkl"),
        ])
        #expect(out == ["a": "abcdef-ghijk", "b": "abcdef-ghi-2", "c": "abcdef-ghi-3"])
        #expect(out.values.allSatisfy { $0.count <= 12 && !$0.hasSuffix("-") && !$0.contains("--") })
    }

    @Test func uppercaseIdFallbackIsLowercased() {
        #expect(AssistantHandle.assign([("3FA9C1D2-0000", "...")]) == ["3FA9C1D2-0000": "s-3fa9"])
    }
}

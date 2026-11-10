import XCTest
@testable import RcHarness

final class PhraseSearchTests: XCTestCase {
    private let phrases = [
        SavedPhrase(title: "继续执行", text: "请继续完成剩余任务", englishTitle: "Continue", englishText: "Please finish the remaining tasks."),
        SavedPhrase(title: "修复问题", text: "修复当前按键映射中的错误", englishTitle: "Fix bugs", englishText: "Repair the mapping."),
        SavedPhrase(title: "总结", text: "总结测试结果", englishTitle: "Résumé", englishText: "Summarize the results."),
    ]

    func testEmptySearchPreservesAllPhrasesAndTheirOrder() {
        XCTAssertEqual(PhraseSearch.filter(phrases, query: ""), phrases)
        XCTAssertEqual(PhraseSearch.filter(phrases, query: "  \n "), phrases)
    }

    func testSearchMatchesBothTitlesAndBothBodies() {
        for query in ["继续", "剩余任务", "continue", "remaining tasks"] {
            XCTAssertEqual(PhraseSearch.filter(phrases, query: query), [phrases[0]])
        }
    }

    func testFuzzySearchAcceptsNonconsecutiveCharacters() {
        XCTAssertEqual(PhraseSearch.filter(phrases, query: "继执"), [phrases[0]])
        XCTAssertEqual(PhraseSearch.filter(phrases, query: "fxbg"), [phrases[1]])
        XCTAssertTrue(PhraseSearch.filter(phrases, query: "行继").isEmpty)
    }

    func testWordsCanMatchDifferentFieldsInEitherOrder() {
        XCTAssertEqual(PhraseSearch.filter(phrases, query: "mapping 修复"), [phrases[1]])
        XCTAssertEqual(PhraseSearch.filter(phrases, query: "修复 mapping"), [phrases[1]])
        XCTAssertTrue(PhraseSearch.filter(phrases, query: "修复 Continue").isEmpty)
    }

    func testSearchIgnoresCaseAccentsAndCharacterWidth() {
        XCTAssertEqual(PhraseSearch.filter(phrases, query: "RESUME"), [phrases[2]])
        XCTAssertEqual(PhraseSearch.filter(phrases, query: "ＦＩＸ"), [phrases[1]])
    }

    func testNoMatchAndEmptyLibraryAreSupported() {
        XCTAssertTrue(PhraseSearch.filter(phrases, query: "不存在的内容").isEmpty)
        XCTAssertTrue(PhraseSearch.filter([], query: "测试").isEmpty)
    }

    func testFuzzyResultsKeepTheLibraryOrderAndOriginalContents() {
        let reordered = [phrases[2], phrases[0], phrases[1]]
        XCTAssertEqual(PhraseSearch.filter(reordered, query: "e"), reordered)
    }
}

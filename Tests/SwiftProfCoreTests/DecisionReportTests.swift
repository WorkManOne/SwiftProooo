import XCTest
import Foundation
@testable import SwiftProfCore

final class DecisionReportTests: XCTestCase {

    func testUnresolvedCause_everyCaseHasANonEmptyGloss() {
        for cause in UnresolvedCause.allCases {
            XCTAssertFalse(cause.gloss.isEmpty, "no gloss for cause '\(cause.rawValue)'")
        }
    }

    func testUnresolvedCause_noDecisionExistsAndIsHighSignal() {
        XCTAssertTrue(UnresolvedCause.allCases.contains(.noDecision))
        XCTAssertEqual(UnresolvedCause.noDecision.rawValue, "no-decision")
        XCTAssertFalse(UnresolvedCause.noDecision.isExplained,
                       "a reporter gap is a lead, not an explanation")
    }
}

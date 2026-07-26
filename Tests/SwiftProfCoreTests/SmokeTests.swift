import XCTest
@testable import SwiftProfCore

final class SmokeTests: XCTestCase {
    func testSymbolTableCanRegister() throws {
        let table = SymbolTable()
        XCTAssertEqual(table.symbols.count, 0)
    }
}

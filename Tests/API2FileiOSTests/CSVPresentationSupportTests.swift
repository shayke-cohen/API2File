import XCTest
@testable import API2FileiOSApp

final class CSVPresentationSupportTests: XCTestCase {
    func testHidesMachineColumnsAndKeepsHumanFields() {
        let text = """
        id,name,status,_url,boardId
        123,Launch Spring Campaign,Working on it,https://example.com/items/123,5093652867
        """

        let model = CSVPresentationSupport.makeModel(from: text)

        XCTAssertEqual(model.totalRowCount, 1)
        XCTAssertEqual(model.visibleColumnCount, 2)
        XCTAssertEqual(model.hiddenColumnCount, 3)
        XCTAssertEqual(model.rows.first?.title, "Launch Spring Campaign")
        XCTAssertEqual(model.rows.first?.fields.map(\.title), ["status"])
        XCTAssertEqual(model.rows.first?.fields.map(\.value), ["Working on it"])
    }

    func testFallsBackToAllColumnsWhenEverythingLooksMachineGenerated() {
        let text = """
        id,boardId
        123,5093652867
        """

        let model = CSVPresentationSupport.makeModel(from: text)

        XCTAssertEqual(model.visibleColumnCount, 2)
        XCTAssertEqual(model.hiddenColumnCount, 0)
        XCTAssertEqual(model.totalRowCount, 1)
    }

    func testParsesQuotedCSVFields() {
        let text = """
        name,notes
        "Amit","Hello, world"
        """

        let rows = CSVPresentationSupport.parseRows(from: text)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["Amit", "Hello, world"])
    }

    func testHidesStructuredPayloadColumnsFromRealWorldCSV() {
        let text = """
        _id,_url,description,groups,items_page,name,state
        18405630648,https://app.monday.com/boards/18405630648,Client accounts board,"[{""id"":""topics"",""title"":""Current Accounts""}]","{""items"":[{""id"":""11602420066"",""name"":""Pear""}]}",Accounts,active
        """

        let model = CSVPresentationSupport.makeModel(from: text)

        XCTAssertEqual(model.totalRowCount, 1)
        XCTAssertEqual(model.rows.first?.title, "Accounts")
        XCTAssertEqual(model.rows.first?.fields.map(\.title), ["description", "state"])
        XCTAssertEqual(model.hiddenColumnCount, 4)
    }
}

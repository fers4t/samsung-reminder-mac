import XCTest
@testable import Samsung_Reminder

final class ContentTests: XCTestCase {
    func testTextRoundTripEscapesXML() {
        let xml = ReminderContent.xml(text: "a < b & \"c\" 'd'", checklist: [])
        XCTAssertEqual(xml, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?><content><TextItem>a &lt; b &amp; &quot;c&quot; &apos;d&apos;</TextItem></content>")
        XCTAssertEqual(ReminderContent.text(record: ["text": .string(xml)]), "a < b & \"c\" 'd'")
    }

    func testChecklistParsingAndPlainText() {
        let items = [ReminderContent.CheckItem(text: "Milk", done: true), .init(text: "  ", done: false), .init(text: "Eggs & ham", done: false)]
        let xml = ReminderContent.xml(text: "note", checklist: items)
        let parsed = ReminderContent.checklist(record: ["text": .string(xml)])
        XCTAssertEqual(parsed, [.init(text: "Milk", done: true), .init(text: "Eggs & ham", done: false)])
        XCTAssertEqual(ReminderContent.plainText(text: "note", checklist: items), "Milk\nEggs & ham\nnote\n")
        XCTAssertEqual(ReminderContent.text(record: ["text": .string(xml)]), "note")
    }

    func testFallsBackToPlainTextWithoutTrailingNewline() {
        XCTAssertEqual(ReminderContent.text(record: ["plainText": .string("hello\n")]), "hello")
        XCTAssertEqual(ReminderContent.text(record: [:]), "")
    }
}

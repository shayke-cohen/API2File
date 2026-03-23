import XCTest
@testable import API2FileCore

final class ICSVCFFormatTests: XCTestCase {

    // MARK: - ICS: Encode Single Event

    func testICSEncodeSingleEvent() throws {
        let records: [[String: Any]] = [
            [
                "id": "evt-001",
                "title": "Team Meeting",
                "description": "Weekly sync",
                "startDate": "2024-06-15T10:00:00Z",
                "endDate": "2024-06-15T11:00:00Z",
                "location": "Room 42"
            ]
        ]
        let data = try ICSFormat.encode(records: records, options: nil)
        let ics = String(data: data, encoding: .utf8)!

        XCTAssertTrue(ics.contains("BEGIN:VCALENDAR"))
        XCTAssertTrue(ics.contains("VERSION:2.0"))
        XCTAssertTrue(ics.contains("PRODID:-//API2File//EN"))
        XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
        XCTAssertTrue(ics.contains("UID:evt-001"))
        XCTAssertTrue(ics.contains("SUMMARY:Team Meeting"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Weekly sync"))
        XCTAssertTrue(ics.contains("DTSTART:20240615T100000Z"))
        XCTAssertTrue(ics.contains("DTEND:20240615T110000Z"))
        XCTAssertTrue(ics.contains("LOCATION:Room 42"))
        XCTAssertTrue(ics.contains("END:VEVENT"))
        XCTAssertTrue(ics.contains("END:VCALENDAR"))
    }

    // MARK: - ICS: Encode Multiple Events

    func testICSEncodeMultipleEvents() throws {
        let records: [[String: Any]] = [
            ["id": "evt-001", "title": "Meeting 1", "startDate": "2024-06-15T10:00:00Z"],
            ["id": "evt-002", "title": "Meeting 2", "startDate": "2024-06-16T14:00:00Z"]
        ]
        let data = try ICSFormat.encode(records: records, options: nil)
        let ics = String(data: data, encoding: .utf8)!

        // Should have exactly one VCALENDAR with two VEVENTs
        XCTAssertEqual(ics.components(separatedBy: "BEGIN:VCALENDAR").count, 2) // 1 occurrence → 2 parts
        XCTAssertEqual(ics.components(separatedBy: "BEGIN:VEVENT").count, 3)    // 2 occurrences → 3 parts
        XCTAssertTrue(ics.contains("SUMMARY:Meeting 1"))
        XCTAssertTrue(ics.contains("SUMMARY:Meeting 2"))
    }

    // MARK: - ICS: Encode Empty Records

    func testICSEncodeEmptyRecordsReturnsEmptyData() throws {
        let data = try ICSFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - ICS: Decode

    func testICSDecodeBackToRecords() throws {
        let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        PRODID:-//API2File//EN\r
        BEGIN:VEVENT\r
        UID:evt-001\r
        DTSTART:20240615T100000Z\r
        DTEND:20240615T110000Z\r
        SUMMARY:Team Meeting\r
        DESCRIPTION:Weekly sync\r
        LOCATION:Room 42\r
        STATUS:CONFIRMED\r
        END:VEVENT\r
        END:VCALENDAR\r\n
        """
        let data = ics.data(using: .utf8)!
        let records = try ICSFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["id"] as? String, "evt-001")
        XCTAssertEqual(records[0]["title"] as? String, "Team Meeting")
        XCTAssertEqual(records[0]["description"] as? String, "Weekly sync")
        XCTAssertEqual(records[0]["location"] as? String, "Room 42")
        XCTAssertEqual(records[0]["status"] as? String, "confirmed")

        // Date should be parsed back to ISO 8601
        let startDate = records[0]["startDate"] as? String
        XCTAssertNotNil(startDate)
        XCTAssertTrue(startDate!.contains("2024-06-15"))
    }

    // MARK: - ICS: Round-trip

    func testICSRoundTrip() throws {
        let original: [[String: Any]] = [
            [
                "id": "evt-round",
                "title": "Roundtrip Event",
                "description": "Testing round-trip",
                "startDate": "2024-07-01T09:00:00Z",
                "endDate": "2024-07-01T10:30:00Z",
                "location": "Conference Room A"
            ]
        ]
        let encoded = try ICSFormat.encode(records: original, options: nil)
        let decoded = try ICSFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["id"] as? String, "evt-round")
        XCTAssertEqual(decoded[0]["title"] as? String, "Roundtrip Event")
        XCTAssertEqual(decoded[0]["description"] as? String, "Testing round-trip")
        XCTAssertEqual(decoded[0]["location"] as? String, "Conference Room A")
    }

    // MARK: - ICS: Custom Field Mapping

    func testICSCustomFieldMapping() throws {
        let options = FormatOptions(fieldMapping: [
            "name": "SUMMARY",
            "start": "DTSTART",
            "end": "DTEND"
        ])
        let records: [[String: Any]] = [
            [
                "name": "Custom Event",
                "start": "2024-08-01T12:00:00Z",
                "end": "2024-08-01T13:00:00Z"
            ]
        ]
        let data = try ICSFormat.encode(records: records, options: options)
        let ics = String(data: data, encoding: .utf8)!

        XCTAssertTrue(ics.contains("SUMMARY:Custom Event"))
        XCTAssertTrue(ics.contains("DTSTART:20240801T120000Z"))
        XCTAssertTrue(ics.contains("DTEND:20240801T130000Z"))

        // Decode back with same options
        let decoded = try ICSFormat.decode(data: data, options: options)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["name"] as? String, "Custom Event")
    }

    // MARK: - ICS: Date Formatting

    func testICSDateFormatting() throws {
        // ISO 8601 with fractional seconds
        let records: [[String: Any]] = [
            [
                "id": "date-test",
                "title": "Date Test",
                "startDate": "2024-12-25T08:30:00.000Z",
                "endDate": "2024-12-25T17:00:00Z"
            ]
        ]
        let data = try ICSFormat.encode(records: records, options: nil)
        let ics = String(data: data, encoding: .utf8)!

        XCTAssertTrue(ics.contains("DTSTART:20241225T083000Z"))
        XCTAssertTrue(ics.contains("DTEND:20241225T170000Z"))
    }

    // MARK: - ICS: Status Mapping

    func testICSStatusMapping() throws {
        let records: [[String: Any]] = [
            ["id": "s1", "title": "Confirmed", "status": "confirmed"],
            ["id": "s2", "title": "Tentative", "status": "tentative"],
            ["id": "s3", "title": "Cancelled", "status": "cancelled"]
        ]
        let data = try ICSFormat.encode(records: records, options: nil)
        let ics = String(data: data, encoding: .utf8)!

        XCTAssertTrue(ics.contains("STATUS:CONFIRMED"))
        XCTAssertTrue(ics.contains("STATUS:TENTATIVE"))
        XCTAssertTrue(ics.contains("STATUS:CANCELLED"))
    }

    // MARK: - ICS: Factory Registration

    func testICSFactoryRegistration() throws {
        let converter = try FormatConverterFactory.converter(for: .ics)
        XCTAssertTrue(converter == ICSFormat.self)
    }

    // MARK: - VCF: Encode Single Contact

    func testVCFEncodeSingleContact() throws {
        let records: [[String: Any]] = [
            [
                "firstName": "John",
                "lastName": "Doe",
                "email": "john@example.com",
                "phone": "+1-555-1234",
                "company": "Acme Inc",
                "jobTitle": "Engineer",
                "notes": "VIP client"
            ]
        ]
        let data = try VCFFormat.encode(records: records, options: nil)
        let vcf = String(data: data, encoding: .utf8)!

        XCTAssertTrue(vcf.contains("BEGIN:VCARD"))
        XCTAssertTrue(vcf.contains("VERSION:3.0"))
        XCTAssertTrue(vcf.contains("FN:John Doe"))
        XCTAssertTrue(vcf.contains("N:Doe;John;;;"))
        XCTAssertTrue(vcf.contains("EMAIL:john@example.com"))
        XCTAssertTrue(vcf.contains("TEL:+1-555-1234"))
        XCTAssertTrue(vcf.contains("ORG:Acme Inc"))
        XCTAssertTrue(vcf.contains("TITLE:Engineer"))
        XCTAssertTrue(vcf.contains("NOTE:VIP client"))
        XCTAssertTrue(vcf.contains("END:VCARD"))
    }

    // MARK: - VCF: Encode Multiple Contacts

    func testVCFEncodeMultipleContacts() throws {
        let records: [[String: Any]] = [
            ["firstName": "Alice", "lastName": "Smith", "email": "alice@example.com"],
            ["firstName": "Bob", "lastName": "Jones", "email": "bob@example.com"]
        ]
        let data = try VCFFormat.encode(records: records, options: nil)
        let vcf = String(data: data, encoding: .utf8)!

        XCTAssertEqual(vcf.components(separatedBy: "BEGIN:VCARD").count, 3) // 2 vCards → 3 parts
        XCTAssertTrue(vcf.contains("FN:Alice Smith"))
        XCTAssertTrue(vcf.contains("FN:Bob Jones"))
    }

    // MARK: - VCF: Encode Empty Records

    func testVCFEncodeEmptyRecordsReturnsEmptyData() throws {
        let data = try VCFFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - VCF: Decode

    func testVCFDecodeBackToRecords() throws {
        let vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Jane Doe\r\nN:Doe;Jane;;;\r\nEMAIL:jane@example.com\r\nTEL:+1-555-5678\r\nORG:Corp\r\nTITLE:Manager\r\nNOTE:Important\r\nEND:VCARD\r\n"
        let data = vcf.data(using: .utf8)!
        let records = try VCFFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["firstName"] as? String, "Jane")
        XCTAssertEqual(records[0]["lastName"] as? String, "Doe")
        XCTAssertEqual(records[0]["email"] as? String, "jane@example.com")
        XCTAssertEqual(records[0]["phone"] as? String, "+1-555-5678")
        XCTAssertEqual(records[0]["company"] as? String, "Corp")
        XCTAssertEqual(records[0]["jobTitle"] as? String, "Manager")
        XCTAssertEqual(records[0]["notes"] as? String, "Important")
    }

    // MARK: - VCF: Round-trip

    func testVCFRoundTrip() throws {
        let original: [[String: Any]] = [
            [
                "firstName": "Test",
                "lastName": "User",
                "email": "test@example.com",
                "phone": "+1-555-0000",
                "company": "TestCo",
                "jobTitle": "Tester"
            ]
        ]
        let encoded = try VCFFormat.encode(records: original, options: nil)
        let decoded = try VCFFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["firstName"] as? String, "Test")
        XCTAssertEqual(decoded[0]["lastName"] as? String, "User")
        XCTAssertEqual(decoded[0]["email"] as? String, "test@example.com")
        XCTAssertEqual(decoded[0]["phone"] as? String, "+1-555-0000")
        XCTAssertEqual(decoded[0]["company"] as? String, "TestCo")
        XCTAssertEqual(decoded[0]["jobTitle"] as? String, "Tester")
    }

    // MARK: - VCF: Custom Field Mapping

    func testVCFCustomFieldMapping() throws {
        let options = FormatOptions(fieldMapping: [
            "givenName": "FN_FIRST",
            "familyName": "FN_LAST",
            "mail": "EMAIL"
        ])
        let records: [[String: Any]] = [
            [
                "givenName": "Custom",
                "familyName": "Name",
                "mail": "custom@example.com"
            ]
        ]
        let data = try VCFFormat.encode(records: records, options: options)
        let vcf = String(data: data, encoding: .utf8)!

        XCTAssertTrue(vcf.contains("FN:Custom Name"))
        XCTAssertTrue(vcf.contains("N:Name;Custom;;;"))
        XCTAssertTrue(vcf.contains("EMAIL:custom@example.com"))

        // Decode back with same options
        let decoded = try VCFFormat.decode(data: data, options: options)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["givenName"] as? String, "Custom")
        XCTAssertEqual(decoded[0]["familyName"] as? String, "Name")
        XCTAssertEqual(decoded[0]["mail"] as? String, "custom@example.com")
    }

    // MARK: - VCF: Handle Missing Fields Gracefully

    func testVCFHandleMissingFieldsGracefully() throws {
        // Only firstName, no other fields
        let records: [[String: Any]] = [
            ["firstName": "Solo"]
        ]
        let data = try VCFFormat.encode(records: records, options: nil)
        let vcf = String(data: data, encoding: .utf8)!

        XCTAssertTrue(vcf.contains("BEGIN:VCARD"))
        XCTAssertTrue(vcf.contains("FN:Solo"))
        XCTAssertFalse(vcf.contains("EMAIL:"))
        XCTAssertFalse(vcf.contains("TEL:"))
        XCTAssertTrue(vcf.contains("END:VCARD"))

        // Decode back
        let decoded = try VCFFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["firstName"] as? String, "Solo")
    }

    // MARK: - VCF: Decode Multiple Contacts

    func testVCFDecodeMultipleContacts() throws {
        let vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Alice Smith\r\nN:Smith;Alice;;;\r\nEMAIL:alice@test.com\r\nEND:VCARD\r\nBEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bob Jones\r\nN:Jones;Bob;;;\r\nEMAIL:bob@test.com\r\nEND:VCARD\r\n"
        let data = vcf.data(using: .utf8)!
        let records = try VCFFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["firstName"] as? String, "Alice")
        XCTAssertEqual(records[0]["lastName"] as? String, "Smith")
        XCTAssertEqual(records[1]["firstName"] as? String, "Bob")
        XCTAssertEqual(records[1]["lastName"] as? String, "Jones")
    }

    // MARK: - VCF: Factory Registration

    func testVCFFactoryRegistration() throws {
        let converter = try FormatConverterFactory.converter(for: .vcf)
        XCTAssertTrue(converter == VCFFormat.self)
    }
}

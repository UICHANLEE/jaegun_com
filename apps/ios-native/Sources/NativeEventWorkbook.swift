import Foundation

enum NativeXLSX {
    /// Stored ZIP OOXML. Every value is an inline string, never an executable formula.
    static func write(sheets: [(name: String, rows: [[String]])]) throws -> Data {
        guard !sheets.isEmpty, sheets.count <= 20, Set(sheets.map(\.name)).count == sheets.count,
              sheets.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 31 && $0.name.rangeOfCharacter(from: CharacterSet(charactersIn: "[]:*?/\\")) == nil && $0.rows.count <= 100000 }) else { throw NativeAPIError.invalidData }
        func xml(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xfffe && $0.value != 0xffff) })).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
        }
        var files: [(String, Data)] = []
        func add(_ path: String, _ value: String) { files.append((path, Data(value.utf8))) }
        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        add("[Content_Types].xml", declaration + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" + sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0+1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined() + "</Types>")
        add("_rels/.rels", declaration + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        add("xl/workbook.xml", declaration + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>" + sheets.enumerated().map { "<sheet name=\"\(xml($0.element.name))\" sheetId=\"\($0.offset+1)\" r:id=\"rId\($0.offset+1)\"/>" }.joined() + "</sheets></workbook>")
        add("xl/_rels/workbook.xml.rels", declaration + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + sheets.indices.map { "<Relationship Id=\"rId\($0+1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0+1).xml\"/>" }.joined() + "</Relationships>")
        for (index, sheet) in sheets.enumerated() {
            let rows = sheet.rows.enumerated().map { row in
                "<row r=\"\(row.offset+1)\">" + row.element.map { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + value : value
                    return "<c t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(safe))</t></is></c>"
                }.joined() + "</row>"
            }.joined()
            add("xl/worksheets/sheet\(index+1).xml", declaration + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>" + rows + "</sheetData></worksheet>")
        }
        var archive = Data(), central = Data()
        func u16(_ value: UInt16) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func u32(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        for (path, bytes) in files {
            guard bytes.count < Int(UInt32.max), archive.count < Int(UInt32.max) else { throw NativeAPIError.invalidData }
            let name = Data(path.utf8), size = UInt32(bytes.count), offset = UInt32(archive.count)
            var crc: UInt32 = 0xffffffff
            for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
            crc ^= 0xffffffff
            archive.append(u32(0x04034b50)); archive.append(u16(20)); archive.append(u16(0x800)); archive.append(u16(0)); archive.append(u16(0)); archive.append(u16(0)); archive.append(u32(crc)); archive.append(u32(size)); archive.append(u32(size)); archive.append(u16(UInt16(name.count))); archive.append(u16(0)); archive.append(name); archive.append(bytes)
            central.append(u32(0x02014b50)); central.append(u16(20)); central.append(u16(20)); central.append(u16(0x800)); central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u32(crc)); central.append(u32(size)); central.append(u32(size)); central.append(u16(UInt16(name.count))); central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u16(0)); central.append(u32(0)); central.append(u32(offset)); central.append(name)
        }
        let centralOffset = UInt32(archive.count); archive.append(central)
        archive.append(u32(0x06054b50)); archive.append(u16(0)); archive.append(u16(0)); archive.append(u16(UInt16(files.count))); archive.append(u16(UInt16(files.count))); archive.append(u32(UInt32(central.count))); archive.append(u32(centralOffset)); archive.append(u16(0))
        return archive
    }
}

enum NativeEventWorkbook {
    static func save(_ state: NativeFieldState) throws -> URL {
        let roster: [[String]] = [["이름", "응답", "교회", "조", "숙소", "차량", "출발지", "참석 시작", "참석 종료", "출석"]] + state.participants.map { p in
            [p.display_name, p.response, p.church_name ?? "", state.groups.first { $0.id == p.group_id }?.name ?? "", state.rooms.first { $0.id == p.room_id }?.name ?? "", state.plan.vehicles.first { $0.id == p.vehicle_id }?.label ?? "", p.survey?.departure ?? "", p.survey?.attendance_start ?? "", p.survey?.attendance_end ?? "", p.checked_at ?? ""]
        }
        let rows = Array(roster.dropFirst())
        let data = try NativeXLSX.write(sheets: [(name: "명단", rows: roster), (name: "조", rows: [["조", "이름", "숙소"]] + rows.map { [$0[3], $0[0], $0[4]] }), (name: "차량", rows: [["차량", "이름", "출발지"]] + rows.map { [$0[5], $0[0], $0[6]] }), (name: "교회", rows: [["교회", "이름", "조"]] + rows.map { [$0[2], $0[0], $0[3]] })])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("행사-현장명단-\(UUID().uuidString).xlsx")
        try data.write(to: url, options: [.atomic, .completeFileProtection]); return url
    }
}

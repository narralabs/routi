import SwiftUI

/// Keep the proposed rows together instead of flattening cells into API fields.
struct SheetValuesPreview: View {
    private let url: URL
    private let range: String
    private let rows: [[String]]

    init?(arguments: String) {
        guard let values = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              Set(values.keys).isSubset(of: ["spreadsheetId", "range", "values"]),
              let id = values["spreadsheetId"] as? String, !id.isEmpty,
              let range = values["range"] as? String,
              let rows = values["values"] as? [[Any]], !rows.isEmpty,
              rows.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 is String || $0 is NSNumber || $0 is NSNull } }),
              let url = URL(string: "https://docs.google.com/spreadsheets/d/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")/edit") else { return nil }
        self.url = url
        self.range = range
        self.rows = rows.map { $0.map { $0 is NSNull ? "Unchanged" : String(describing: $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Link("Open spreadsheet", destination: url)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cells to update").font(.caption).foregroundStyle(.secondary)
                Text(range).textSelection(.enabled)
            }
            Text("New values").font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                Text(rows[row][column].isEmpty ? "Empty" : rows[row][column])
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(minWidth: 80, maxWidth: 180, alignment: .leading)
                                    .background(.background)
                                    .border(.quaternary, width: 0.5)
                            }
                        }
                    }
                }
            }.defaultScrollAnchor(.topLeading)
                .frame(maxHeight: 200)
        }
    }
}

import SwiftUI

/// The editable key/value list: a stdio server's environment, a remote one's headers, in the
/// inspector and in the add sheet alike.
struct KeyValueEditor: View {
    /// The section label tells sighted users which list this is; the noun is what tells everyone
    /// else, so it stays specific — "environment variable", not "entry".
    enum Kind {
        case env, headers

        var title: String {
            switch self {
            case .env: "Env"
            case .headers: "Headers"
            }
        }

        var noun: String {
            switch self {
            case .env: "environment variable"
            case .headers: "header"
            }
        }

        var placeholder: (key: String, value: String) {
            switch self {
            case .env: ("KEY", "value")
            case .headers: ("Header", "value")
            }
        }
    }

    let kind: Kind
    @Binding var rows: [KeyValueRow]
    /// Runs when a row is submitted or removed. The add sheet passes nothing and still wants the
    /// action installed: it is what keeps Return in the field, off the sheet's default button.
    let commit: () -> Void

    init(_ kind: Kind, rows: Binding<[KeyValueRow]>, commit: @escaping () -> Void = {}) {
        self.kind = kind
        self._rows = rows
        self.commit = commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                SectionLabel(kind.title)
                Spacer(minLength: 0)
                Button { rows.append(KeyValueRow(key: "", value: "")) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.pressable)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Add \(kind.noun)")
            }
            ForEach($rows) { $row in
                HStack(spacing: Space.xs) {
                    TextField(kind.placeholder.key, text: $row.key)
                    TextField(kind.placeholder.value, text: $row.value)
                    Button {
                        rows.removeAll { $0.id == row.id }
                        commit()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(row.key.isEmpty ? "empty" : row.key) \(kind.noun)")
                }
                .textFieldStyle(.roundedBorder)
                .font(Typography.mono)
            }
        }
        .onSubmit(commit)
    }
}

/// Identity that survives editing: keying rows by their key would renumber the list mid-word.
struct KeyValueRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

extension [KeyValueRow] {
    /// Sorted, since a dictionary has no order of its own and the rows would otherwise come back
    /// in a different arrangement every time the form is re-seeded.
    init(_ dictionary: [String: String]) {
        self = dictionary.sorted { $0.key < $1.key }.map { KeyValueRow(key: $0.key, value: $0.value) }
    }

    /// Rows with a blank key are the half-typed ones; they are dropped rather than sent as "".
    var dictionary: [String: String] {
        Dictionary(compactMap { row -> (String, String)? in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : (key, row.value)
        }, uniquingKeysWith: { _, later in later })
    }
}

import SwiftUI

/// The editable key/value list: a stdio server's environment, a remote one's headers, in the
/// inspector and in the add sheet alike.
struct KeyValueEditor: View {
    let title: String
    /// What one row is, spoken. The section label tells sighted users which list this is; the noun
    /// is what tells everyone else, so it stays specific — "environment variable", not "entry".
    let noun: String
    let placeholder: (key: String, value: String)
    @Binding var rows: [KeyValueRow]
    /// Run when a row is submitted or removed. The inspector is editing a live server and pushes
    /// the change; the add sheet is still assembling one and has nothing to push yet.
    var commit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                SectionLabel(title)
                Spacer(minLength: 0)
                Button { rows.append(KeyValueRow(key: "", value: "")) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.pressable)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Add \(noun)")
            }
            ForEach($rows) { $row in
                HStack(spacing: Space.xs) {
                    TextField(placeholder.key, text: $row.key)
                        .onSubmit(commit)
                    TextField(placeholder.value, text: $row.value)
                        .onSubmit(commit)
                    Button {
                        rows.removeAll { $0.id == row.id }
                        commit()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(row.key.isEmpty ? "empty" : row.key) \(noun)")
                }
                .textFieldStyle(.roundedBorder)
                .font(Typography.mono)
            }
        }
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
        var out: [String: String] = [:]
        for row in self {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = row.value }
        }
        return out
    }
}

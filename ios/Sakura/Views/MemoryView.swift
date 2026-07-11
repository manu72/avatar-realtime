import SwiftUI

/// What Sakura remembers: read-only summary, raw-JSON editor, and a clear
/// button — the native version of the web app's memory modal.
struct MemoryView: View {
    @EnvironmentObject var vm: SessionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var record: MemoryRecord?
    @State private var jsonText = ""
    @State private var feedback: String?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if let record {
                    summarySection(record)
                    editorSection
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }
                if let feedback {
                    Text(feedback).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Sakura's notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Forget all", role: .destructive) { confirmClear = true }
                }
            }
            .confirmationDialog("Sakura will forget everything about you. Sure?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Forget everything", role: .destructive) {
                    Task {
                        await vm.memory.clear()
                        await reload()
                    }
                }
            }
            .task { await reload() }
        }
    }

    private func summarySection(_ record: MemoryRecord) -> some View {
        let m = record.memory.bounded()
        let p = m.profile
        return Section("What she remembers") {
            row("Chats so far", "\(record.interactionCount)")
            if let name = p.preferredName { row("Your name", name) }
            if !p.facts.isEmpty { row("Facts", p.facts.map { "• " + $0 }.joined(separator: "\n")) }
            if !p.preferences.isEmpty { row("Preferences", p.preferences.map { "• " + $0 }.joined(separator: "\n")) }
            if !p.projects.isEmpty { row("Projects & topics", p.projects.map { "• " + $0 }.joined(separator: "\n")) }
            if !m.relationshipSummary.isEmpty { row("Relationship notes", m.relationshipSummary) }
            if m.isEmpty {
                Text("Nothing yet — Sakura writes her notes shortly after each chat ends.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private var editorSection: some View {
        Section("Edit raw JSON") {
            TextEditor(text: $jsonText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 160)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save changes") {
                Task { await saveJSON() }
            }
        }
    }

    private func reload() async {
        let r = await vm.memory.current
        record = r
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonText = String(decoding: (try? encoder.encode(r.memory)) ?? Data(), as: UTF8.self)
        feedback = nil
    }

    private func saveJSON() async {
        guard let data = jsonText.data(using: .utf8),
              let doc = try? JSONDecoder().decode(MemoryDocument.self, from: data) else {
            feedback = "That's not valid memory JSON."
            return
        }
        await vm.memory.replaceDocument(doc)
        await reload()
    }
}

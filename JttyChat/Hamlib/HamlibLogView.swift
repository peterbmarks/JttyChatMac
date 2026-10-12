import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Hamlib Log window: a live, scrolling view of Hamlib's debug output
/// as it talks to the transceiver, with JttyChat's own notes about each
/// operation and the full Hamlib error trace for anything that fails.
struct HamlibLogView: View {
    @EnvironmentObject private var log: HamlibLog
    @State private var followTail = true
    @State private var isExporting = false
    @State private var exportDocument: HamlibLogDocument?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(log.entries) { entry in
                        HamlibLogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if log.entries.isEmpty {
                    ContentUnavailableView("No Hamlib Activity",
                                           systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Connect to or tune the rig to see Hamlib's log here."))
                }
            }
            .onChange(of: log.entries.last?.id) { _, lastID in
                if followTail, let lastID {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onAppear {
                if let lastID = log.entries.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 300)
        .toolbar {
            ToolbarItem {
                Picker("Level", selection: $log.level) {
                    ForEach(HamlibLogLevel.allCases) { level in
                        Text(level.name).tag(level)
                    }
                }
                .help("How much detail Hamlib logs")
            }
            ToolbarItem {
                Toggle(isOn: $followTail) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                }
                .help("Keep scrolled to the newest entry")
            }
            ToolbarItem {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.plainText, forType: .string)
                }
                .help("Copy the whole log")
                .disabled(log.entries.isEmpty)
            }
            ToolbarItem {
                Button("Save", systemImage: "square.and.arrow.down") {
                    exportDocument = HamlibLogDocument(text: log.plainText)
                    isExporting = true
                }
                    .help("Save the log to a text file")
                    .disabled(log.entries.isEmpty)
            }
            ToolbarItem {
                Button("Clear", systemImage: "trash") { log.clear() }
                    .help("Clear the log")
                    .disabled(log.entries.isEmpty)
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: exportDocument,
                      contentType: .plainText,
                      defaultFilename: "Hamlib Log.txt") { _ in exportDocument = nil }
    }
}

private struct HamlibLogRow: View {
    let entry: HamlibLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                .foregroundStyle(.secondary)
            Text(entry.level.name)
                .foregroundStyle(entry.level.color)
                .frame(width: 56, alignment: .leading)
            Text(entry.text)
                .foregroundStyle(entry.fromApp && entry.level.rawValue > HamlibLogLevel.warning.rawValue
                                 ? .primary : entry.level.color)
                .fontWeight(entry.fromApp ? .semibold : .regular)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, entry.level == .error || entry.level == .bug ? 4 : 0)
        .background(entry.level == .error || entry.level == .bug ? Color.red.opacity(0.08) : .clear)
    }
}

/// Wraps the log's text for .fileExporter.
private struct HamlibLogDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

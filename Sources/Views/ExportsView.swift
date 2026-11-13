import SwiftUI

// The export in progress and how many wait behind it. Details lists every export, as Safari lists its downloads.
struct ExportsLine: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let export = model.runningExport ?? model.exports.first(where: { $0.status == .waiting }) {
            let waiting = model.exports.filter { $0.status == .waiting && $0 !== export }.count
            HStack(spacing: 12) {
                ProgressView(value: export.progress)
                    .frame(maxWidth: 200)
                Text(verbatim: "Saving “\(export.name)” · \(export.statusText)" + (waiting == 0 ? "" : " · \(waiting) more waiting"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Details") { model.showsExports.toggle() }
                    .linkButton()
                    .popover(isPresented: $model.showsExports, arrowEdge: .top) {
                        ExportsList()
                            .environment(model)
                    }
                Spacer(minLength: 0)
                Button("Cancel") { model.cancel(export) }
            }
        }
    }
}

// Every export since the app opened, newest first, with what each is doing.
struct ExportsList: View {
    @Environment(StitchModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Exports")
                .font(.headline)
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.exports.reversed()) { export in
                        ExportRow(export: export)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Button("Show Log") {
                    model.showsExports = false
                    openWindow(id: "export-log")
                }
                Spacer()
                if model.exports.contains(where: { !$0.isActive }) {
                    Button("Clear Finished") { model.clearFinishedExports() }
                }
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 400)
    }
}

struct ExportRow: View {
    @Environment(StitchModel.self) private var model
    let export: Export

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: export.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if export.status == .running {
                    ProgressView(value: export.progress)
                        .controlSize(.small)
                }
                Text(verbatim: export.statusText)
                    .font(.caption)
                    .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if export.isActive {
                Button {
                    model.cancel(export)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(export.status == .waiting ? "Cancel" : "Stop Saving")
                .accessibilityLabel(export.status == .waiting ? "Cancel" : "Stop Saving")
            } else if case .done = export.status {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([export.output])
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var failed: Bool {
        if case .failed = export.status { true } else { false }
    }
}

// What exports and searches have done, with the time of each step, for working out why something is slow or failed.
struct ExportLogView: View {
    @Environment(StitchModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.logLines.isEmpty {
                ContentUnavailableView("Nothing Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Searches and exports appear here as they happen."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.logLines) { line in
                                Text(verbatim: line.formatted)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.logLines.last?.id) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack {
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logLines.map(\.formatted).joined(separator: "\n"), forType: .string)
                }
                .disabled(model.logLines.isEmpty)
                Spacer()
                Button("Clear") { model.clearLog() }
                    .disabled(model.logLines.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 280)
    }
}

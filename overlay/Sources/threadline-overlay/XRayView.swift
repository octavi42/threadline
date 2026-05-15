import AppKit
import SwiftUI

struct XRayView: View {
    let snap: SourceSnapshot

    @State private var state: FetchState = .idle

    enum FetchState {
        case idle
        case loading
        case success(XRayReport)
        case failure(XRayError)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .onAppear {
            if case .idle = state { fetch() }
        }
        .onChange(of: snap.id) { _ in
            state = .idle
            fetch()
        }
    }

    private var header: some View {
        HStack {
            Text("X-RAY")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: fetch) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("running threadline xray…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        case .success(let report):
            ReportContent(report: report)
        case .failure(let err):
            VStack(alignment: .leading, spacing: 6) {
                Text(err.localizedDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Retry") { fetch() }
                    .controlSize(.small)
            }
        }
    }

    private func fetch() {
        guard let cwd = snap.cwd, !cwd.isEmpty else {
            state = .failure(.notInGitRepo)
            return
        }
        state = .loading
        let session = snap.jsonlPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = XRayFetcher.fetch(cwd: cwd, session: session)
            DispatchQueue.main.async {
                switch result {
                case .success(let r): self.state = .success(r)
                case .failure(let e): self.state = .failure(e)
                }
            }
        }
    }
}

private struct ReportContent: View {
    let report: XRayReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("base \(report.base)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("·")
                    .foregroundColor(.secondary)
                Text("\(report.files.count) file\(report.files.count == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            if report.files.isEmpty {
                Text("No overlap between the diff and the session.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(report.files) { file in
                    FileCard(file: file, repo: report.repo)
                }
            }
        }
    }
}

private struct FileCard: View {
    let file: XRayFile
    let repo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(file.path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ForEach(file.editCounts, id: \.tool) { ec in
                    Chip(text: "\(ec.count)× \(ec.tool)", color: .secondary)
                }
                if file.retryCount > 0 {
                    Chip(text: "\(file.retryCount) retries", color: .orange)
                }
            }
            if !file.framingPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(file.framingPrompts, id: \.self) { p in
                        HStack(alignment: .top, spacing: 0) {
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: 2)
                            Text(p.text)
                                .font(.system(size: 11))
                                .padding(.leading, 8)
                                .padding(.vertical, 2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            ForEach(file.hunks.indices, id: \.self) { idx in
                HunkRow(hunk: file.hunks[idx])
            }
            HStack(spacing: 8) {
                EditorButton(label: "Open in Cursor", scheme: "cursor", file: file, repo: repo)
                EditorButton(label: "Open in VS Code", scheme: "vscode", file: file, repo: repo)
                Spacer()
            }
        }
        .padding(12)
        .background(Color(white: 0.10))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.20), lineWidth: 1)
        )
    }
}

private struct HunkRow: View {
    let hunk: XRayHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("@@ +\(hunk.newStart),\(hunk.newCount) −\(hunk.baseStart),\(hunk.baseCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            if !hunk.body.isEmpty {
                DiffBody(lines: hunk.body)
            }
            ForEach(hunk.tests.indices, id: \.self) { i in
                TestRow(test: hunk.tests[i])
            }
        }
    }
}

private struct DiffBody: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { i in
                DiffLineRow(line: lines[i])
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.25))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(white: 0.18), lineWidth: 1)
        )
    }
}

private struct DiffLineRow: View {
    let line: String

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .textSelection(.enabled)
    }

    private var prefix: Character? { line.first }
    private var textColor: Color {
        switch prefix {
        case "+": return Color(red: 0.49, green: 0.91, blue: 0.53)  // #7ee787
        case "-": return Color(red: 1.00, green: 0.63, blue: 0.60)  // #ffa198
        default:  return .secondary
        }
    }
    private var rowBackground: Color {
        switch prefix {
        case "+": return Color(red: 0.25, green: 0.73, blue: 0.31).opacity(0.10)
        case "-": return Color(red: 0.97, green: 0.32, blue: 0.29).opacity(0.10)
        default:  return .clear
        }
    }
}

private struct TestRow: View {
    let test: XRayTest

    var body: some View {
        HStack(spacing: 6) {
            Text(glyph)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(glyphColor)
                .frame(width: 12)
            Text(test.command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var glyph: String {
        switch test.exitStatus {
        case 0: return "✓"
        case -1: return "⚠"
        case .some: return "✗"
        case .none: return "·"
        }
    }
    private var glyphColor: Color {
        switch test.exitStatus {
        case 0: return .green
        case -1: return .orange
        case .some: return .red
        case .none: return .secondary
        }
    }
}

private struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .cornerRadius(8)
    }
}

private struct EditorButton: View {
    let label: String
    let scheme: String   // "cursor" | "vscode"
    let file: XRayFile
    let repo: String?

    var body: some View {
        Button(action: open) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .controlSize(.small)
        .disabled(repo == nil)
    }

    private func open() {
        guard let repo = repo else { return }
        let absolute = (repo as NSString).appendingPathComponent(file.path)
        let line = file.hunks.first?.newStart ?? 1
        // Cursor and VS Code both honor scheme://file/<abs>:<line>
        let encoded = absolute.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? absolute
        let urlString = "\(scheme)://file\(encoded.hasPrefix("/") ? "" : "/")\(encoded):\(line)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

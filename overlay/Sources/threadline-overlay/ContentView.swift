import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("threadline")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(Date(), style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Divider().opacity(0.3)
            ForEach(model.snapshots) { snap in
                row(snap)
            }
            if model.snapshots.isEmpty {
                Text("no sources detected")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ s: SourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(s.tool)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(badgeColor(s.tool).opacity(0.25))
                    )
                    .foregroundColor(badgeColor(s.tool))
                Text(s.summaryLine)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(s.subtitleLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func badgeColor(_ tool: String) -> Color {
        switch tool {
        case "Claude": return .orange
        case "Codex":  return .green
        case "Cursor": return .purple
        default:       return .gray
        }
    }
}

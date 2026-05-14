import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        HSplitView {
            AgentsList(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            DetailsPane(snapshot: model.selectedSnapshot)
                .frame(minWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - left sidebar

private struct AgentsList: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AGENTS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(model.snapshots.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if model.snapshots.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("no recent agents")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("sessions from the last 7 days show here")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color.secondary.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.selectedID },
                    set: { model.selectedID = $0 })) {
                        ForEach(model.snapshots) { snap in
                            AgentRow(snap: snap)
                                .tag(snap.id)
                        }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct AgentRow: View {
    let snap: SourceSnapshot

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: snap.state).frame(width: 7, height: 7)
            BadgeView(label: snap.badge, color: badgeColor(snap.tool))
            VStack(alignment: .leading, spacing: 1) {
                Text(snap.projectName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(snap.activityLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(snap.timeAgoShort)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func badgeColor(_ tool: String) -> Color {
        switch tool {
        case "Claude": return Color(red: 1.0, green: 0.55, blue: 0.10)
        case "Codex":  return Color(red: 0.30, green: 0.85, blue: 0.45)
        case "Cursor": return Color(red: 0.70, green: 0.50, blue: 1.0)
        default:       return .gray
        }
    }
}

// MARK: - right details

private struct DetailsPane: View {
    let snapshot: SourceSnapshot?

    var body: some View {
        if let s = snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(s)
                    Divider()
                    statsGrid(s)
                    if let task = s.currentTask, !task.isEmpty {
                        section(label: "CURRENT TASK", text: task)
                    }
                    if let tool = s.lastTool, !tool.isEmpty {
                        section(label: "LAST ACTION", text: tool)
                    }
                    if let last = s.lastText, !last.isEmpty {
                        section(label: "LAST MESSAGE", text: last, mono: true)
                    }
                    if let note = s.note, !note.isEmpty {
                        section(label: "NOTE", text: note)
                    }
                    Spacer(minLength: 16)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text("select an agent")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ s: SourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StateDot(state: s.state).frame(width: 9, height: 9)
                Text(s.tool)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                Text("·")
                    .foregroundColor(.secondary)
                Text(s.projectName)
                    .font(.system(size: 18, design: .monospaced))
                Spacer()
                Text(s.timeAgoShort)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(s.displayCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func statsGrid(_ s: SourceSnapshot) -> some View {
        let branchStr: String? = {
            guard let b = s.branch else { return nil }
            if let d = s.dirtyCount, d > 0 { return "\(b)+\(d)" }
            return b
        }()
        let items: [(String, String?)] = [
            ("model",    s.model),
            ("branch",   branchStr),
            ("context",  s.contextPercent.map { String(format: "%.0f%%", $0 * 100) }),
            ("cost",     s.costUSD.flatMap { $0 > 0 ? String(format: "$%.2f", $0) : nil }),
            ("state",    s.state == .none ? nil : s.state.rawValue),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                         spacing: 8) {
            ForEach(items.compactMap { pair -> (String, String)? in
                guard let v = pair.1, !v.isEmpty else { return nil }
                return (pair.0, v)
            }, id: \.0) { (label, value) in
                stat(label: label, value: value)
            }
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func section(label: String, text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: mono ? 11 : 12, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - shared primitives

struct StateDot: View {
    let state: SourceState
    var body: some View {
        Circle().fill(fill).overlay(strokeOverlay)
    }
    private var fill: Color {
        switch state {
        case .running:  return Color(red: 1.0, green: 0.78, blue: 0.10)
        case .awaiting: return Color(red: 1.0, green: 0.50, blue: 0.10)
        case .idle:     return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .error:    return Color(red: 1.0, green: 0.30, blue: 0.30)
        case .stale:    return Color(white: 0.35)
        case .none:     return .clear
        }
    }
    @ViewBuilder private var strokeOverlay: some View {
        if state == .none { Circle().stroke(Color(white: 0.4), lineWidth: 1) }
    }
}

struct BadgeView: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color.opacity(0.55), lineWidth: 0.5)
            )
            .foregroundColor(color)
    }
}

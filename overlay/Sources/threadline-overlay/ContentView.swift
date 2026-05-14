import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tasks    = "Tasks"
    case files    = "Files"
    case summary  = "Summary"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var model: SessionModel
    @State private var tab: DetailTab = .overview

    var body: some View {
        HSplitView {
            AgentsList(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            DetailsPane(model: model, tab: $tab)
                .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedID) { _ in
            if tab == .summary { model.requestSummaryForSelection() }
        }
    }
}

// MARK: - sidebar

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
                    Text("no open agents")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.selectedID },
                    set: { model.selectedID = $0 })) {
                        ForEach(model.snapshots) { snap in
                            AgentRow(snap: snap).tag(snap.id)
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

// MARK: - details pane with tabs

private struct DetailsPane: View {
    @ObservedObject var model: SessionModel
    @Binding var tab: DetailTab

    var body: some View {
        if let snap = model.selectedSnapshot {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(snap: snap)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .onChange(of: tab) { newValue in
                    if newValue == .summary { model.requestSummaryForSelection() }
                }
                Divider().padding(.top, 8)
                ScrollView {
                    Group {
                        switch tab {
                        case .overview: OverviewView(snap: snap)
                        case .tasks:    TasksView(snap: snap)
                        case .files:    FilesView(snap: snap)
                        case .summary:  SummaryView(model: model, snap: snap)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
}

private struct DetailHeader: View {
    let snap: SourceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StateDot(state: snap.state).frame(width: 9, height: 9)
                Text(snap.tool)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                Text("·").foregroundColor(.secondary)
                Text(snap.projectName)
                    .font(.system(size: 17, design: .monospaced))
                Spacer()
                Text(snap.timeAgoShort)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(snap.displayCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - tabs

private struct OverviewView: View {
    let snap: SourceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statsGrid
            if let task = snap.currentTask, !task.isEmpty {
                section(label: "CURRENT TASK", text: task)
            }
            if let last = snap.lastTool, !last.isEmpty {
                section(label: "LAST ACTION", text: last)
            }
            if let lastText = snap.lastText, !lastText.isEmpty {
                section(label: "LAST MESSAGE", text: lastText, mono: true)
            }
            Spacer(minLength: 0)
        }
    }
    private var statsGrid: some View {
        let branchStr: String? = {
            guard let b = snap.branch else { return nil }
            if let d = snap.dirtyCount, d > 0 { return "\(b)+\(d)" }
            return b
        }()
        let burn = snap.costBurnPerMin.map { String(format: "$%.3f/min", $0) }
        let block = snap.blockRemainingFormatted.map { "\($0) left in block" }
        let items: [(String, String?)] = [
            ("model",       snap.model),
            ("branch",      branchStr),
            ("context",     snap.contextPercent.map { String(format: "%.0f%%", $0 * 100) }),
            ("cost",        snap.costUSD.flatMap { $0 > 0 ? String(format: "$%.2f", $0) : nil }),
            ("burn rate",   burn),
            ("5h block",    block),
            ("turns",       snap.userTurns + snap.assistantTurns > 0
                            ? "\(snap.userTurns) user · \(snap.assistantTurns) asst" : nil),
            ("files edited", snap.filesEdited.isEmpty ? nil : "\(snap.filesEdited.count)"),
            ("tasks",       snap.tasks.isEmpty ? nil :
                            "\(snap.tasksDone)/\(snap.tasks.count) done"),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                         spacing: 8) {
            ForEach(items.compactMap { p -> (String, String)? in
                guard let v = p.1, !v.isEmpty else { return nil }
                return (p.0, v)
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
            Text(value).font(.system(size: 12, design: .monospaced))
        }
    }
    private func section(label: String, text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: mono ? 11 : 12,
                              design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TasksView: View {
    let snap: SourceSnapshot
    var body: some View {
        if snap.tasks.isEmpty {
            Text("no tasks tracked")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    counter("DONE",        snap.tasksDone,       .green)
                    counter("IN PROGRESS", snap.tasksInProgress, .yellow)
                    counter("PENDING",     snap.tasksPending,    .secondary)
                }
                .padding(.bottom, 4)
                ForEach(snap.tasks) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(symbol(t.status))
                            .foregroundColor(color(t.status))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 14, alignment: .leading)
                        Text(t.content)
                            .font(.system(size: 12, design: .default))
                            .strikethrough(t.status == "completed", color: .secondary)
                            .foregroundColor(t.status == "completed" ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
    private func symbol(_ s: String) -> String {
        switch s {
        case "completed":   return "[x]"
        case "in_progress": return "[▶]"
        default:            return "[ ]"
        }
    }
    private func color(_ s: String) -> Color {
        switch s {
        case "completed":   return .green
        case "in_progress": return .yellow
        default:            return .secondary
        }
    }
    private func counter(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

private struct FilesView: View {
    let snap: SourceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top: tool call counts
            if !snap.toolCallCounts.isEmpty {
                Text("TOOL CALLS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                FlowChips(items: snap.toolCallCounts
                    .sorted { $0.value > $1.value }
                    .map { "\($0.key): \($0.value)" })
                Divider().padding(.vertical, 4)
            }
            Text("FILES EDITED (\(snap.filesEdited.count))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            if snap.filesEdited.isEmpty {
                Text("none yet")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                ForEach(snap.filesEdited, id: \.self) { path in
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        // Simple two-column wrap; works fine for our short chip strings.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                 count: 3), spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                    )
                    .foregroundColor(.primary)
            }
        }
    }
}

private struct SummaryView: View {
    @ObservedObject var model: SessionModel
    let snap: SourceSnapshot
    var body: some View {
        if let text = model.summaries[snap.id], !text.isEmpty {
            Text(text)
                .font(.system(size: 13, design: .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Summarizing this session…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("Set ANTHROPIC_API_KEY or write to ~/.threadline/config.json with {\"anthropic_api_key\":\"sk-ant-…\"} to enable LLM summaries (claude-haiku-4-5, cached per session).")
                    .font(.system(size: 11, design: .default))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { model.requestSummaryForSelection() }
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

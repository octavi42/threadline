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
                            AgentRow(snap: snap, summary: model.summaries[snap.id])
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
    let summary: String?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StateDot(state: snap.state).frame(width: 7, height: 7).padding(.top, 4)
            BadgeView(label: snap.badge, color: badgeColor(snap.tool)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(snap.projectName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Prefer the LLM-generated summary; fall back to the
                // activity heuristic until it arrives.
                Text(secondaryLine)
                    .font(.system(size: 10, design: .default))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text(snap.timeAgoShort)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
    private var secondaryLine: String {
        if let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        return snap.activityLine
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StateDot(state: snap.state).frame(width: 10, height: 10)
                Text(snap.tool)
                    .font(.system(size: 20, weight: .semibold))
                Text(snap.projectName)
                    .font(.system(size: 20, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(snap.timeAgoShort)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(snap.displayCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.secondary.opacity(0.7))
        }
    }
}

// MARK: - tabs

private struct OverviewView: View {
    let snap: SourceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statsGrid
            if let task = snap.currentTask, !task.isEmpty {
                section(label: "Current task", text: task)
            }
            if let last = snap.lastTool, !last.isEmpty {
                section(label: "Last action", text: last, mono: true)
            }
            if let lastText = snap.lastText, !lastText.isEmpty {
                section(label: "Last message", text: lastText)
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
        let block = snap.blockRemainingFormatted.map { "\($0) left" }
        let items: [(String, String?)] = [
            ("model",        snap.model),
            ("branch",       branchStr),
            ("context",      snap.contextPercent.map { String(format: "%.0f%%", $0 * 100) }),
            ("cost",         snap.costUSD.flatMap { $0 > 0 ? String(format: "$%.2f", $0) : nil }),
            ("burn rate",    burn),
            ("5h block",     block),
            ("turns",        snap.userTurns + snap.assistantTurns > 0
                             ? "\(snap.userTurns) user · \(snap.assistantTurns) asst" : nil),
            ("files edited", snap.filesEdited.isEmpty ? nil : "\(snap.filesEdited.count)"),
            ("tasks",        snap.tasks.isEmpty ? nil :
                             "\(snap.tasksDone)/\(snap.tasks.count) done"),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                         alignment: .leading, spacing: 14) {
            ForEach(items.compactMap { p -> (String, String)? in
                guard let v = p.1, !v.isEmpty else { return nil }
                return (p.0, v)
            }, id: \.0) { (label, value) in
                stat(label: label, value: value)
            }
        }
    }
    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
    private func section(label: String, text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: mono ? 12 : 13,
                              design: mono ? .monospaced : .default))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TasksView: View {
    let snap: SourceSnapshot
    var body: some View {
        if snap.tasks.isEmpty {
            Text("No tasks tracked yet.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    counter("done",        snap.tasksDone,       Color(red: 0.30, green: 0.80, blue: 0.50))
                    counter("in progress", snap.tasksInProgress, Color(red: 1.0,  green: 0.78, blue: 0.10))
                    counter("pending",     snap.tasksPending,    .secondary)
                }
                .padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snap.tasks) { t in
                        TaskRow(task: t)
                    }
                }
            }
        }
    }
    private func counter(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(color)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.secondary)
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Single Unicode glyph — fits in any monospaced cell, no
            // line-wrapping problems.
            Text(glyph)
                .font(.system(size: 13))
                .foregroundColor(glyphColor)
                .frame(width: 14, alignment: .center)
            Text(task.content)
                .font(.system(size: 13))
                .foregroundColor(task.status == "completed" ? .secondary : .primary)
                .strikethrough(task.status == "completed", color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
    private var glyph: String {
        switch task.status {
        case "completed":   return "●"
        case "in_progress": return "◐"
        default:            return "○"
        }
    }
    private var glyphColor: Color {
        switch task.status {
        case "completed":   return Color(red: 0.30, green: 0.80, blue: 0.50)
        case "in_progress": return Color(red: 1.0,  green: 0.78, blue: 0.10)
        default:            return .secondary
        }
    }
}

private struct FilesView: View {
    let snap: SourceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !snap.toolCallCounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TOOL CALLS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                    FlowChips(items: snap.toolCallCounts
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key) · \($0.value)" })
                }
            }
            if !snap.toolTokenEstimate.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TOKENS PER TOOL")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                    FlowChips(items: snap.toolTokenEstimate
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key) · \(SourceSnapshot.formatTokens($0.value)) tk" })
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("FILES EDITED (\(snap.filesEdited.count))")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                    if snap.linesAdded > 0 || snap.linesRemoved > 0 {
                        HStack(spacing: 6) {
                            Text("+\(snap.linesAdded)")
                                .foregroundColor(Color(red: 0.30, green: 0.80, blue: 0.50))
                            Text("−\(snap.linesRemoved)")
                                .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.45))
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                    Spacer()
                }
                if snap.filesEdited.isEmpty {
                    Text("None yet.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(snap.filesEdited, id: \.self) { path in
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                 count: 3), spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
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
            VStack(alignment: .leading, spacing: 6) {
                Text("SUMMARY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundColor(.secondary)
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(2)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Summarising this session…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text("Uses your installed `claude -p` or `codex exec` — no separate API key needed. Falls back to ANTHROPIC_API_KEY if both CLIs are missing.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary.opacity(0.8))
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

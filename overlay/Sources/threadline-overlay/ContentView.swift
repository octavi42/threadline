import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tasks    = "Tasks"
    case files    = "Files"
    case summary  = "Summary"
    var id: String { rawValue }
}

private func badgeColor(_ tool: String) -> Color {
    switch tool {
    case "Claude": return Color(red: 1.0, green: 0.55, blue: 0.10)
    case "Codex":  return Color(red: 0.30, green: 0.85, blue: 0.45)
    case "Cursor": return Color(red: 0.70, green: 0.50, blue: 1.0)
    default:       return .gray
    }
}

private func sectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .tracking(0.5)
        .foregroundColor(.secondary)
}

private func workStatusColor(_ status: WorkStatus) -> Color {
    switch status {
    case .needsYou:     return Color(red: 1.0, green: 0.55, blue: 0.10)
    case .testsFailed:  return Color(red: 1.0, green: 0.30, blue: 0.30)
    case .stuck:        return Color(red: 0.95, green: 0.35, blue: 0.65)
    case .risky:        return Color(red: 1.0, green: 0.78, blue: 0.10)
    case .ready:        return Color(red: 0.30, green: 0.85, blue: 0.45)
    case .working:      return Color(red: 0.40, green: 0.70, blue: 1.0)
    case .done:         return .secondary
    }
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
    @State private var expandedFolderIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AGENTS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(model.folders.count)/\(model.snapshots.count)")
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
                        ForEach(model.folders) { folder in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedFolderIDs.contains(folder.id) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedFolderIDs.insert(folder.id)
                                        } else {
                                            expandedFolderIDs.remove(folder.id)
                                        }
                                    }
                                )
                            ) {
                                ForEach(folder.snapshots) { snap in
                                    AgentRow(snap: snap,
                                             summary: model.summaries[snap.id],
                                             workState: model.workStates[snap.id])
                                        .tag(snap.id)
                                }
                            }
                            label: {
                                FolderHeader(folder: folder)
                                    .padding(.leading, 4)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selectedID = folder.selectionID
                                    }
                            }
                            .tag(folder.selectionID)
                        }
                }
                .listStyle(.sidebar)
                .onAppear {
                    if expandedFolderIDs.isEmpty {
                        expandedFolderIDs = Set(model.folders.map(\.id))
                    }
                }
                .onChange(of: model.folders) { folders in
                    let visible = Set(folders.map(\.id))
                    expandedFolderIDs = expandedFolderIDs.intersection(visible)
                    if expandedFolderIDs.isEmpty {
                        expandedFolderIDs = visible
                    }
                }
            }
        }
    }
}

private struct FolderHeader: View {
    let folder: SessionFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(folder.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(folder.snapshots.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(folder.displayCwd)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }
}

private struct FolderStateDots: View {
    let snapshots: [SourceSnapshot]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(snapshots.prefix(3).enumerated()), id: \.offset) { _, snap in
                StateDot(state: snap.state)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 22, alignment: .leading)
    }
}

private struct AgentRow: View {
    let snap: SourceSnapshot
    let summary: String?
    let workState: WorkState?
    var body: some View {
        let work = workState ?? snap.workState
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(workStatusColor(work.status))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            BadgeView(label: snap.badge, color: badgeColor(snap.tool)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(snap.tool)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(work.status.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(workStatusColor(work.status))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(work.reason)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let s = secondaryLine {
                    Text(s)
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            Text(snap.timeAgoShort)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
    private var secondaryLine: String? {
        if let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return SourceSnapshot.compactLine(s)
        }
        let fallback = snap.activityLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback == "—" ? nil : fallback
    }
}

// MARK: - details pane with tabs

private struct DetailsPane: View {
    @ObservedObject var model: SessionModel
    @Binding var tab: DetailTab

    var body: some View {
        if let snap = model.selectedSnapshot {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(snap: snap, workState: model.workStates[snap.id] ?? snap.workState)
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        switch tab {
                        case .overview: OverviewView(snap: snap,
                                                     workState: model.workStates[snap.id] ?? snap.workState)
                        case .tasks:    TasksView(snap: snap)
                        case .files:    FilesView(model: model, snap: snap)
                        case .summary:  SummaryView(model: model, snap: snap)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let folder = model.selectedFolder {
            FolderDetailsPane(model: model, folder: folder)
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

private struct FolderDetailsPane: View {
    @ObservedObject var model: SessionModel
    let folder: SessionFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderDetailHeader(folder: folder)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    FolderStatsView(folder: folder)
                    FolderSubagentsView(model: model, folder: folder)
                    FolderTasksView(folder: folder)
                    FolderFilesView(model: model, folder: folder)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct FolderDetailHeader: View {
    let folder: SessionFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FolderStateDots(snapshots: folder.snapshots)
                Text(folder.name)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                Spacer()
                if let latest = folder.latestSnapshot {
                    Text(latest.timeAgoShort)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Text(folder.displayCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.secondary.opacity(0.7))
        }
    }
}

private struct FolderStatsView: View {
    let folder: SessionFolder

    var body: some View {
        let stats = folder.stats
        let items: [(String, String?)] = [
            ("subagents", "\(folder.snapshots.count)"),
            ("running", stats.running > 0 ? "\(stats.running)" : nil),
            ("awaiting", stats.awaiting > 0 ? "\(stats.awaiting)" : nil),
            ("tools", stats.toolsSummary.isEmpty ? nil : stats.toolsSummary),
            ("tasks", stats.taskCount == 0 ? nil : "\(stats.tasksDone)/\(stats.taskCount) done"),
            ("files edited", stats.uniqueFileCount == 0 ? nil : "\(stats.uniqueFileCount)"),
        ]

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
                 alignment: .leading, spacing: 14) {
            ForEach(items.compactMap { item -> (String, String)? in
                guard let value = item.1, !value.isEmpty else { return nil }
                return (item.0, value)
            }, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
        }
    }
}

private struct FolderSubagentsView: View {
    @ObservedObject var model: SessionModel
    let folder: SessionFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SUBAGENTS")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(folder.snapshots) { snap in
                    Button {
                        model.selectedID = snap.id
                    } label: {
                        let work = model.workStates[snap.id] ?? snap.workState
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(workStatusColor(work.status))
                                .frame(width: 7, height: 7)
                                .padding(.top, 4)
                            BadgeView(label: snap.badge, color: badgeColor(snap.tool))
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(snap.tool)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(work.status.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(workStatusColor(work.status))
                                    Text(snap.metricsLine)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(snap.timeAgoShort)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Text(summary(for: snap))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func summary(for snap: SourceSnapshot) -> String {
        if let s = model.summaries[snap.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }
        return snap.activityLine
    }
}

private struct FolderTasksView: View {
    let folder: SessionFolder

    var body: some View {
        let tasks = folder.snapshots.flatMap(\.tasks)
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("TASKS")
                ForEach(Array(tasks.prefix(8).enumerated()), id: \.offset) { _, task in
                    TaskRow(task: task)
                }
            }
        }
    }
}

private struct FolderFilesView: View {
    @ObservedObject var model: SessionModel
    let folder: SessionFolder

    private var mergedChanges: [FileChangeGroup] {
        var byPath: [String: [FileEditOp]] = [:]
        for snap in folder.snapshots {
            for group in snap.fileChanges {
                byPath[group.path, default: []].append(contentsOf: group.edits)
            }
        }
        return byPath.map { path, ops in
            FileChangeGroup(path: path, edits: ops)
        }.sorted { $0.path < $1.path }
    }

    private var fallbackFiles: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for path in folder.snapshots.flatMap(\.filesEdited) where !seen.contains(path) {
            seen.insert(path)
            out.append(path)
        }
        return out
    }

    var body: some View {
        let changes = mergedChanges
        let fileCount = changes.isEmpty ? fallbackFiles.count : changes.count
        if fileCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("FILES EDITED (\(fileCount))")
                if !changes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(changes) { group in
                            FileChangeRow(group: group,
                                          isExpanded: model.expandedFiles.contains(group.path),
                                          toggle: {
                                if model.expandedFiles.contains(group.path) {
                                    model.expandedFiles.remove(group.path)
                                } else {
                                    model.expandedFiles.insert(group.path)
                                }
                            })
                        }
                    }
                } else {
                    ForEach(fallbackFiles.prefix(12), id: \.self) { path in
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct DetailHeader: View {
    let snap: SourceSnapshot
    let workState: WorkState
    var body: some View {
        let work = workState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(workStatusColor(work.status))
                    .frame(width: 10, height: 10)
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
    let workState: WorkState
    var body: some View {
        let work = workState
        VStack(alignment: .leading, spacing: 18) {
            WorkSummaryView(snap: snap, work: work)
            statsGrid
            if let task = snap.currentTask, !task.isEmpty {
                section(label: "Current task", text: task)
            }
            if let last = snap.lastTool, !last.isEmpty {
                section(label: "Last action", text: last, mono: true)
            }
            if snap.activityLine != "—" {
                section(label: "Current activity", text: snap.activityLine)
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

private struct WorkSummaryView: View {
    let snap: SourceSnapshot
    let work: WorkState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(work.status.rawValue)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(workStatusColor(work.status))
                Text(work.reason)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2),
                     alignment: .leading, spacing: 12) {
                item("changed", changedText)
                item("evidence", evidenceText)
                item("risk", riskText)
                item("next action", work.nextAction)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(workStatusColor(work.status).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(workStatusColor(work.status).opacity(0.28), lineWidth: 0.5)
        )
    }

    private var changedText: String {
        let fileCount = max(snap.fileChanges.count, snap.filesEdited.count)
        if fileCount > 0 {
            return "\(fileCount) file\(fileCount == 1 ? "" : "s")"
        }
        if let dirty = snap.dirtyCount, dirty > 0 {
            return "\(dirty) dirty file\(dirty == 1 ? "" : "s")"
        }
        return "none detected"
    }

    private var evidenceText: String {
        switch work.status {
        case .ready:
            return "tests passed"
        case .testsFailed:
            return "tests failed"
        case .risky:
            return "no tests found"
        case .needsYou:
            return "blocked"
        case .stuck:
            return "retries/errors"
        case .working:
            return "in progress"
        case .done:
            return WorkStatusResolver.hasCodeChanges(snap) ? "unknown" : "not code"
        }
    }

    private var riskText: String {
        switch work.status {
        case .ready:
            return "low"
        case .risky, .testsFailed, .stuck:
            return "needs review"
        case .needsYou:
            return "needs input"
        case .working:
            return "not finished"
        case .done:
            return WorkStatusResolver.hasCodeChanges(snap) ? "unknown" : "none"
        }
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
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
    @ObservedObject var model: SessionModel
    let snap: SourceSnapshot
    @State private var showAllFiles = false
    @State private var xrayExpanded = false

    private static let defaultVisibleFiles = 15

    private var fileCount: Int {
        snap.fileChanges.isEmpty ? snap.filesEdited.count : snap.fileChanges.count
    }

    private var visibleFileChanges: [FileChangeGroup] {
        if showAllFiles { return snap.fileChanges }
        return Array(snap.fileChanges.prefix(Self.defaultVisibleFiles))
    }

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
                    Text("FILES EDITED (\(fileCount))")
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
                if !snap.fileChanges.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleFileChanges) { group in
                            FileChangeRow(group: group,
                                          isExpanded: model.expandedFiles.contains(group.path),
                                          toggle: {
                                if model.expandedFiles.contains(group.path) {
                                    model.expandedFiles.remove(group.path)
                                } else {
                                    model.expandedFiles.insert(group.path)
                                }
                            })
                        }
                        if snap.fileChanges.count > Self.defaultVisibleFiles {
                            Button(showAllFiles ? "Show fewer files" : "Show \(snap.fileChanges.count - Self.defaultVisibleFiles) more files") {
                                showAllFiles.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        }
                    }
                } else if !snap.filesEdited.isEmpty {
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
                } else {
                    Text("None yet.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            DisclosureGroup(isExpanded: $xrayExpanded) {
                if xrayExpanded {
                    XRayView(snap: snap)
                }
            } label: {
                Text("X-RAY ANALYSIS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct FileChangeRow: View {
    let group: FileChangeGroup
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    Text((group.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        if group.linesAdded > 0 {
                            Text("+\(group.linesAdded)")
                                .foregroundColor(Color(red: 0.30, green: 0.80, blue: 0.50))
                        }
                        if group.linesRemoved > 0 {
                            Text("−\(group.linesRemoved)")
                                .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.45))
                        }
                        Text("\(group.edits.count) edit\(group.edits.count == 1 ? "" : "s")")
                            .foregroundColor(.secondary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isExpanded {
                Text((group.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
                    .padding(.bottom, 4)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text((group.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    ForEach(group.edits) { op in
                        EditOpView(op: op)
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 10)
            }

            Divider().opacity(0.5)
        }
    }
}

private struct EditOpView: View {
    let op: FileEditOp

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(op.tool)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(toolColor.opacity(0.15))
                    )
                    .foregroundColor(toolColor)
                if !op.note.isEmpty {
                    Text(op.note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if !op.patchDisplay.lines.isEmpty {
                DiffBlock(display: op.patchDisplay, mode: .patch)
            } else {
                if !op.oldTextDisplay.lines.isEmpty {
                    DiffBlock(display: op.oldTextDisplay, mode: .removed)
                }
                if !op.newTextDisplay.lines.isEmpty {
                    DiffBlock(display: op.newTextDisplay, mode: .added)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    private var toolColor: Color {
        switch op.tool {
        case "Edit":        return Color(red: 0.40, green: 0.70, blue: 1.0)
        case "Write":       return Color(red: 0.30, green: 0.80, blue: 0.50)
        case "apply_patch": return Color(red: 1.0,  green: 0.65, blue: 0.20)
        default:            return .secondary
        }
    }
}

private enum DiffMode { case added, removed, patch }

private struct DiffBlock: View {
    let display: DiffDisplay
    let mode: DiffMode

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(display.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
                if display.hasMore {
                    Text("… \(display.hiddenCount) more lines")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(bgColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(bgColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func lineView(_ line: String) -> some View {
        HStack(spacing: 0) {
            Text(prefix)
                .foregroundColor(prefixColor)
                .frame(width: 14, alignment: .center)
            Text(line.isEmpty ? " " : line)
                .foregroundColor(.primary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 4)
        .padding(.vertical, 0.5)
        .background(lineBackground(line))
    }

    private func lineBackground(_ line: String) -> Color {
        switch mode {
        case .added:   return Color(red: 0.30, green: 0.80, blue: 0.50).opacity(0.06)
        case .removed: return Color(red: 0.95, green: 0.45, blue: 0.45).opacity(0.06)
        case .patch:
            if line.hasPrefix("+") { return Color(red: 0.30, green: 0.80, blue: 0.50).opacity(0.06) }
            if line.hasPrefix("-") { return Color(red: 0.95, green: 0.45, blue: 0.45).opacity(0.06) }
            return .clear
        }
    }

    private var prefix: String {
        switch mode {
        case .added:   return "+"
        case .removed: return "−"
        case .patch:   return ""
        }
    }

    private var prefixColor: Color {
        switch mode {
        case .added:   return Color(red: 0.30, green: 0.80, blue: 0.50)
        case .removed: return Color(red: 0.95, green: 0.45, blue: 0.45)
        case .patch:   return .secondary
        }
    }

    private var bgColor: Color {
        switch mode {
        case .added:   return Color(red: 0.30, green: 0.80, blue: 0.50)
        case .removed: return Color(red: 0.95, green: 0.45, blue: 0.45)
        case .patch:   return Color.secondary
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
                Text("CURRENT")
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

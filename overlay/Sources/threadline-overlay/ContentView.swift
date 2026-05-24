import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case tasks    = "Tasks"
    case files    = "Files"
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
    @Bindable var model: SessionModel
    let onJump: (SourceSnapshot) -> Void
    @State private var tab: DetailTab = .overview

    var body: some View {
        HSplitView {
            AgentsList(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            DetailsPane(model: model, tab: $tab, onJump: onJump)
                .frame(minWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedID) {
            model.requestSummaryForSelection()
        }
    }
}

// MARK: - sidebar

private struct JumpButton: View {
    let snap: SourceSnapshot
    let onJump: (SourceSnapshot) -> Void

    private var enabled: Bool { JumpBack.canJump(to: snap) }

    var body: some View {
        Button {
            onJump(snap)
        } label: {
            Text("Open")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundColor(enabled ? .accentColor : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(enabled ? 0.12 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor.opacity(enabled ? 0.35 : 0.15), lineWidth: 0.5)
        )
        .help(JumpBack.jumpLabel(for: snap))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Ticks every second — green when data synced within the last 3s.
private struct SyncIndicator: View {
    let refreshedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let refreshedAt {
                let age = Int(context.date.timeIntervalSince(refreshedAt))
                let fresh = age < 3
                HStack(spacing: 4) {
                    Circle()
                        .fill(fresh
                              ? Color(red: 0.35, green: 0.85, blue: 0.45)
                              : Color.secondary.opacity(0.45))
                        .frame(width: 5, height: 5)
                    Text(age == 0 ? "live sync" : "sync \(age)s")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(fresh ? Color(red: 0.35, green: 0.75, blue: 0.45) : .secondary)
                }
                .help("Last inbox refresh \(age)s ago")
                .accessibilityIdentifier("threadline-sync-indicator")
            }
        }
    }
}

private struct AgentsList: View {
    @Bindable var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("INBOX")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if model.hiddenOlderCount > 0 {
                    Button(model.showOlderSessions ? "Hide older" : "Show \(model.hiddenOlderCount) older") {
                        model.setShowOlderSessions(!model.showOlderSessions)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                }
                if model.hiddenDoneCount > 0 {
                    Button(model.showInactiveSessions ? "Hide done" : "Show \(model.hiddenDoneCount) done") {
                        model.setShowInactiveSessions(!model.showInactiveSessions)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                }
                if model.hiddenCursorHistoryCount > 0 {
                    Button(model.showCursorHistorySessions ? "Hide history" : "Show \(model.hiddenCursorHistoryCount) history") {
                        model.setShowCursorHistorySessions(!model.showCursorHistorySessions)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                }
                Text("\(model.inboxFolderCount)/\(model.inboxSnapshotCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                SyncIndicator(refreshedAt: model.lastRefreshAt)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.inboxRows.isEmpty {
                        inboxEmptyState
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    ForEach(model.inboxRows) { row in
                        InboxRowView(row: row, model: model)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var inboxEmptyState: some View {
        VStack(spacing: 6) {
            if !model.hasAnySnapshots {
                Text("no open agents")
            } else {
                Text("all sessions quiet")
                if model.hiddenOlderCount > 0 || model.hiddenDoneCount > 0 {
                    HStack(spacing: 10) {
                        if model.hiddenOlderCount > 0 {
                            Button("Show \(model.hiddenOlderCount) older") {
                                model.setShowOlderSessions(true)
                            }
                            .buttonStyle(.plain)
                        }
                        if model.hiddenDoneCount > 0 {
                            Button("Show \(model.hiddenDoneCount) done") {
                                model.setShowInactiveSessions(true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// One flat sidebar row with stable identity for incremental refreshes.
private struct InboxRowView: View {
    let row: InboxRow
    @Bindable var model: SessionModel

    private var isSelected: Bool { model.selectedID == row.selectionTag }

    var body: some View {
        switch row {
        case .folderHeader(let cwd):
            FolderSidebarRow(cwd: cwd, isSelected: isSelected, model: model)
        case .agent(let snapshotID, _, let isFirst, let isLast):
            if let cell = model.cell(for: snapshotID) {
                Button {
                    model.selectedID = row.selectionTag
                } label: {
                    AgentInboxRow(cell: cell, isFirst: isFirst, isLast: isLast)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private struct AgentInboxRow: View {
    @Bindable var cell: SnapshotCell
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let _ = cell.revision
        let snap = cell.snapshot
        AgentRow(snap: snap,
                 workState: snap.workState,
                 lastAppliedAt: cell.lastAppliedAt)
            .padding(.leading, 12)
            .padding(.top, isFirst ? 6 : 2)
            .padding(.bottom, isLast ? 10 : 0)
    }
}

/// Ticks relative timestamps without invalidating the whole app model.
private struct RelativeTimeText: View {
    let updatedAt: Date?
    var font: Font = .system(size: 10, design: .monospaced)

    var body: some View {
        if let updatedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SourceSnapshot.formatTimeAgo(from: updatedAt, relativeTo: context.date))
                    .font(font)
                    .foregroundColor(.secondary)
            }
        } else {
            Text("—")
                .font(font)
                .foregroundColor(.secondary)
        }
    }
}

/// Folder row with separate keyboard-accessible selection and disclosure controls.
private struct FolderSidebarRow: View {
    let cwd: String
    let isSelected: Bool
    @Bindable var model: SessionModel

    private var folder: SessionFolder? { model.inboxFolder(cwd: cwd) }
    private var isExpanded: Bool { model.isFolderExpanded(cwd) }

    var body: some View {
        if let folder = folder {
            HStack(alignment: .top, spacing: 4) {
                Button {
                    model.toggleFolderExpansion(cwd)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse sessions" : "Expand sessions")

                Button {
                    model.selectedID = folder.selectionID
                } label: {
                    FolderHeader(folder: folder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint("Select folder sessions")
            }
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            .padding(.leading, 4)
            .padding(.top, 2)
            .padding(.bottom, isExpanded ? 4 : 2)
        }
    }
}

private struct FolderHeader: View {
    let folder: SessionFolder

    private var trust: FolderTrustSummary {
        folder.trustSummary(workStates: [:])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(folder.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(folder.snapshots.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let rollup = trust.rollupLine {
                Text(rollup)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(workStatusColor(folderWorstStatus))
                    .lineLimit(2)
            }
            Text(folder.displayCwd)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }

    private var folderWorstStatus: WorkStatus {
        let order: [WorkStatus] = [.needsYou, .testsFailed, .stuck, .risky, .ready, .working, .done]
        for status in order where (trust.counts[status] ?? 0) > 0 {
            return status
        }
        return .done
    }
}

/// Sidebar actions — hide generic "Jump back"; status already implies it (Enter still jumps).
private func inboxNextAction(_ work: WorkState) -> String? {
    let action = work.nextAction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !action.isEmpty, action != "Jump back" else { return nil }
    return action
}

/// Flashes green for 2s after a row receives fresh snapshot data.
private struct RowFreshnessBadge: View {
    let appliedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = Int(context.date.timeIntervalSince(appliedAt))
            let fresh = age < 2
            Text(fresh ? "just updated" : "upd \(age)s")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(fresh
                                 ? Color(red: 0.35, green: 0.85, blue: 0.45)
                                 : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill((fresh
                               ? Color(red: 0.35, green: 0.85, blue: 0.45)
                               : Color.secondary).opacity(fresh ? 0.15 : 0.08))
                )
                .help("Row data refreshed \(age)s ago")
        }
    }
}

private struct AgentRow: View {
    let snap: SourceSnapshot
    let workState: WorkState?
    var lastAppliedAt: Date?

    var body: some View {
        let work = workState ?? snap.workState
        HStack(alignment: .top, spacing: 6) {
            BadgeView(label: snap.badge, color: badgeColor(snap.tool)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if snap.livePid != nil {
                        Circle()
                            .fill(Color(red: 0.35, green: 0.85, blue: 0.45))
                            .frame(width: 6, height: 6)
                            .help("Live agent process")
                            .accessibilityIdentifier("session-live-\(snap.id)")
                    }
                    Text(snap.tool)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(work.status.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(workStatusColor(work.status))
                        .lineLimit(1)
                        .accessibilityIdentifier("session-status-\(snap.id)")
                    if snap.livePid != nil, let lastAppliedAt {
                        RowFreshnessBadge(appliedAt: lastAppliedAt)
                    }
                }
                if snap.activityLine != "—" {
                    Text(snap.activityLine)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(snap.activityLine)
                }
                if let action = inboxNextAction(work) {
                    Text("→ \(action)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(workStatusColor(work.status).opacity(0.9))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            RelativeTimeText(updatedAt: snap.updatedAt)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("session-row-\(snap.id)")
    }
}

// MARK: - details pane with tabs

private struct DetailsPane: View {
    @Bindable var model: SessionModel
    @Binding var tab: DetailTab
    let onJump: (SourceSnapshot) -> Void

    var body: some View {
        Group {
            if let selectedID = model.selectedID, selectedID.hasPrefix("folder:") {
                FolderDetailsPane(model: model, folderCWD: String(selectedID.dropFirst("folder:".count)))
            } else if let selectedID = model.selectedID {
                AgentDetailsPane(model: model,
                                 snapshotID: selectedID,
                                 tab: $tab,
                                 onJump: onJump)
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
}

private struct AgentDetailsPane: View {
    @Bindable var model: SessionModel
    let snapshotID: String
    @Binding var tab: DetailTab
    let onJump: (SourceSnapshot) -> Void

    var body: some View {
        if let cell = model.cell(for: snapshotID) {
            AgentDetailsContent(model: model,
                                cell: cell,
                                tab: $tab,
                                onJump: onJump)
        } else {
            VStack {
                Spacer()
                Text("session ended")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AgentDetailsContent: View {
    @Bindable var model: SessionModel
    @Bindable var cell: SnapshotCell
    @Binding var tab: DetailTab
    let onJump: (SourceSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(snap: cell.snapshot, onJump: onJump)
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
            Divider().padding(.top, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .overview:
                        OverviewView(model: model, cell: cell)
                    case .tasks:
                        LiveTasksView(cell: cell)
                    case .files:
                        LiveFilesView(model: model, cell: cell)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LiveTasksView: View {
    @Bindable var cell: SnapshotCell

    var body: some View {
        TasksView(snap: cell.snapshot)
    }
}

private struct LiveFilesView: View {
    @Bindable var model: SessionModel
    @Bindable var cell: SnapshotCell

    var body: some View {
        FilesView(model: model, snap: cell.snapshot)
    }
}

private struct FolderDetailsPane: View {
    @Bindable var model: SessionModel
    let folderCWD: String

    private var folder: SessionFolder? { model.inboxFolder(cwd: folderCWD) ?? model.folders.first { $0.cwd == folderCWD } }

    var body: some View {
        if let folder = folder {
            folderDetails(folder)
        } else {
            VStack {
                Spacer()
                Text("folder unavailable")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func folderDetails(_ folder: SessionFolder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FolderDetailHeader(folder: folder)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    FolderConflictStripView(model: model, folder: folder)
                    FolderTrustBoardView(model: model, folder: folder)
                    FolderStatsView(folder: folder)
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

private struct FolderConflictStripView: View {
    @Bindable var model: SessionModel
    let folder: SessionFolder

    private var conflicts: [FileAgentConflict] {
        folder.fileConflicts(workStates: [:])
    }

    var body: some View {
        if !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("CONFLICTS")
                Text("Same file, different trust — pick which agent to trust.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                ForEach(conflicts.prefix(5)) { conflict in
                    FileConflictCard(conflict: conflict, model: model)
                }
                if conflicts.count > 5 {
                    Text("\(conflicts.count - 5) more file conflicts")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private struct FileConflictCard: View {
    let conflict: FileAgentConflict
    @Bindable var model: SessionModel

    var body: some View {
        Button {
            if let id = conflict.recommendedSnapshotID {
                model.selectedID = id
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.10))
                    Text(conflict.fileName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(conflict.toolsLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(conflict.contributors.filter {
                        !WorkStatusResolver.isInactiveInbox($0.work)
                    }, id: \.snapshotID) { contributor in
                        HStack(spacing: 6) {
                            Text(contributor.summaryLine)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                }
                Text("→ \(conflict.suggestion)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.10))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(red: 1.0, green: 0.78, blue: 0.10).opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FolderTrustBoardView: View {
    @Bindable var model: SessionModel
    let folder: SessionFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("TRUST BOARD")
            if let rollup = folder.trustSummary(workStates: [:]).rollupLine {
                Text(rollup)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
    }
}

private struct FolderStatsView: View {
    let folder: SessionFolder

    var body: some View {
        let stats = folder.stats
        let items: [(String, String?)] = [
            ("running", stats.running > 0 ? "\(stats.running)" : nil),
            ("awaiting", stats.awaiting > 0 ? "\(stats.awaiting)" : nil),
            ("tools", stats.toolsSummary.isEmpty ? nil : stats.toolsSummary),
            ("tasks", stats.taskCount == 0 ? nil : "\(stats.tasksDone)/\(stats.taskCount) done"),
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
    @Bindable var model: SessionModel
    let folder: SessionFolder
    @State private var showAllFiles = false

    private static let defaultVisibleFiles = 12

    private var files: [FolderMergedFile] { folder.mergedFiles() }
    private var summary: FolderFilesSummary { folder.filesSummary() }

    private var visibleFiles: [FolderMergedFile] {
        if showAllFiles { return files }
        return Array(files.prefix(Self.defaultVisibleFiles))
    }

    var body: some View {
        if summary.fileCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("FILES")
                FolderFilesSummaryBar(summary: summary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleFiles) { file in
                        FolderProjectFileRow(file: file, folder: folder, model: model)
                    }
                    if files.count > Self.defaultVisibleFiles {
                        Button(showAllFiles ? "Show fewer files" : "Show \(files.count - Self.defaultVisibleFiles) more files") {
                            showAllFiles.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

private struct FolderFilesSummaryBar: View {
    let summary: FolderFilesSummary

    var body: some View {
        HStack(spacing: 8) {
            Text("\(summary.fileCount) changed")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            if summary.linesAdded > 0 || summary.linesRemoved > 0 {
                HStack(spacing: 6) {
                    if summary.linesAdded > 0 {
                        Text("+\(summary.linesAdded)")
                            .foregroundColor(Color(red: 0.30, green: 0.80, blue: 0.50))
                    }
                    if summary.linesRemoved > 0 {
                        Text("−\(summary.linesRemoved)")
                            .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.45))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct FolderProjectFileRow: View {
    let file: FolderMergedFile
    let folder: SessionFolder
    @Bindable var model: SessionModel

    private var isExpanded: Bool { model.expandedFiles.contains(file.path) }

    private static let maxVisibleEdits = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpanded()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        if file.linesAdded > 0 {
                            Text("+\(file.linesAdded)")
                                .foregroundColor(Color(red: 0.30, green: 0.80, blue: 0.50))
                        }
                        if file.linesRemoved > 0 {
                            Text("−\(file.linesRemoved)")
                                .foregroundColor(Color(red: 0.95, green: 0.45, blue: 0.45))
                        }
                        if file.editCount > 0 {
                            Text("\(file.editCount) edit\(file.editCount == 1 ? "" : "s")")
                                .foregroundColor(.secondary)
                        } else {
                            Text("path only")
                                .foregroundColor(.secondary)
                        }
                        if !file.toolsLabel.isEmpty {
                            Text(file.toolsLabel)
                                .foregroundColor(Color.secondary.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                FolderProjectFileExpanded(file: file, folder: folder, model: model,
                                          maxEdits: Self.maxVisibleEdits)
                    .padding(.leading, 20)
                    .padding(.bottom, 10)
            }

            Divider().opacity(0.5)
        }
    }

    private func toggleExpanded() {
        if isExpanded {
            model.expandedFiles.remove(file.path)
        } else {
            model.expandedFiles.insert(file.path)
        }
    }
}

private struct FolderProjectFileExpanded: View {
    let file: FolderMergedFile
    let folder: SessionFolder
    @Bindable var model: SessionModel
    let maxEdits: Int

    private var visibleEdits: [MergedFileEdit] {
        Array(file.edits.prefix(maxEdits))
    }

    private var hiddenEditCount: Int {
        max(0, file.edits.count - visibleEdits.count)
    }

    private var contributingSnapshots: [SourceSnapshot] {
        file.sourceSnapshotIDs.compactMap { id in
            folder.snapshots.first { $0.id == id }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((file.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if !contributingSnapshots.isEmpty {
                HStack(spacing: 6) {
                    Text("Sessions")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                    ForEach(contributingSnapshots) { snap in
                        Button {
                            model.selectedID = snap.id
                        } label: {
                            HStack(spacing: 4) {
                                BadgeView(label: snap.badge, color: badgeColor(snap.tool))
                                Text(snap.tool)
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(badgeColor(snap.tool))
                        .help(snap.activityLine)
                    }
                }
            }

            if file.hasDiffContent {
                ForEach(visibleEdits) { merged in
                    EditOpView(op: merged.op)
                }
                if hiddenEditCount > 0 {
                    Text("\(hiddenEditCount) more edit\(hiddenEditCount == 1 ? "" : "s") across agents")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Path recorded — open a session for full diff.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct DetailHeader: View {
    let snap: SourceSnapshot
    let onJump: (SourceSnapshot) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(snap.tool)
                    .font(.system(size: 20, weight: .semibold))
                Text(snap.projectName)
                    .font(.system(size: 20, weight: .regular, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                JumpButton(snap: snap, onJump: onJump)
                    .layoutPriority(1)
                RelativeTimeText(updatedAt: snap.updatedAt, font: .system(size: 11, design: .monospaced))
            }
            Text(snap.displayCwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.secondary.opacity(0.7))
        }
    }
}

// MARK: - tabs

private struct OverviewView: View {
    @Bindable var model: SessionModel
    @Bindable var cell: SnapshotCell

    var body: some View {
        let snap = cell.snapshot
        VStack(alignment: .leading, spacing: 18) {
            WorkSummaryView(snap: snap, work: snap.workState)
            SessionBriefSection(model: model, snap: snap)
            statsGrid(for: snap)
            Spacer(minLength: 0)
        }
        .onAppear { model.requestSummaryForSelection() }
    }

    private func statsGrid(for snap: SourceSnapshot) -> some View {
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

private struct SessionBriefSection: View {
    @Bindable var model: SessionModel
    let snap: SourceSnapshot

    private var brief: String? {
        let llm = model.summaries[snap.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let llm, !llm.isEmpty { return llm }
        return SessionModel.deterministicBrief(for: snap)
    }

    private var waitsForLLM: Bool {
        guard let path = snap.jsonlPath else { return false }
        return Summarizer.shouldSummarize(tool: snap.tool, jsonlPath: path)
            && (model.summaries[snap.id]?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SESSION")
            if let text = brief, !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if waitsForLLM {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building session brief…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text("Local Ollama, then Claude/Codex. Local AI: \(LocalLLM.statusLabel).")
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary.opacity(0.8))
            } else {
                Text("No session summary available.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
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
    @Bindable var model: SessionModel
    let snap: SourceSnapshot
    @State private var showAllFiles = false

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

// MARK: - shared primitives

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

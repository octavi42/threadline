import SwiftUI

struct ContentView: View {
    @ObservedObject var model: SessionModel

    // MARK: theme-derived colors

    private var primaryText: Color {
        model.themeIsDark ? Color(white: 0.97) : Color(white: 0.10)
    }
    private var secondaryText: Color {
        model.themeIsDark ? Color(white: 0.58) : Color(white: 0.40)
    }
    private var dividerColor: Color {
        model.themeIsDark ? Color(white: 0.18) : Color(white: 0.82)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: model.themeBackground).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 4) {
                header
                Rectangle().fill(dividerColor).frame(height: 1)
                ForEach(model.snapshots) { snap in
                    SourceRow(snap: snap,
                              primary: primaryText,
                              secondary: secondaryText)
                }
                if model.snapshots.isEmpty {
                    Text("no sources detected")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        let totals = aggregate(model.snapshots)
        let scopeText: String? = model.scopeCwd.map {
            ($0 as NSString).abbreviatingWithTildeInPath
        }
        return HStack(spacing: 10) {
            Text("threadline")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(secondaryText)
            if let scope = scopeText {
                Text("· \(scope)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            HStack(spacing: 10) {
                if totals.active > 0 {
                    HStack(spacing: 4) {
                        StateDot(state: .running).frame(width: 6, height: 6)
                        Text("\(totals.active) active")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(secondaryText)
                    }
                }
                if let cost = totals.cost {
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(secondaryText)
                }
                if let ctx = totals.avgContext {
                    Text(String(format: "%.0f%% ctx", ctx * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(secondaryText)
                }
                Text(Date(), style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(secondaryText)
            }
        }
    }

    private func aggregate(_ ss: [SourceSnapshot]) -> (active: Int, cost: Double?, avgContext: Double?) {
        let active = ss.filter { $0.state == .running || $0.state == .awaiting }.count
        let costs = ss.compactMap { $0.costUSD }
        let cost: Double? = costs.isEmpty ? nil : costs.reduce(0, +)
        let ctxs  = ss.compactMap { $0.contextPercent }
        let avg:  Double? = ctxs.isEmpty ? nil : ctxs.reduce(0, +) / Double(ctxs.count)
        return (active, cost, avg)
    }
}

// MARK: - SourceRow

private struct SourceRow: View {
    let snap: SourceSnapshot
    let primary: Color
    let secondary: Color

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: snap.state).frame(width: 8, height: 8)
            BadgeView(label: snap.badge, color: badgeColor(snap.tool))
                .frame(width: 38, alignment: .leading)
            Text(snap.activityLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(snap.state == .stale ? secondary : primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(snap.metricsLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(secondary)
                .lineLimit(1)
                .layoutPriority(0.5)
            Text(snap.timeAgoShort)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(secondary)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - dot + badge primitives

private struct StateDot: View {
    let state: SourceState
    var body: some View {
        Circle()
            .fill(fill)
            .overlay(strokeOverlay)
    }
    private var fill: Color {
        switch state {
        case .running:  return Color(red: 1.0, green: 0.78, blue: 0.10)     // yellow
        case .awaiting: return Color(red: 1.0, green: 0.50, blue: 0.10)     // orange
        case .idle:     return Color(red: 0.30, green: 0.85, blue: 0.45)    // green
        case .error:    return Color(red: 1.0, green: 0.30, blue: 0.30)     // red
        case .stale:    return Color(white: 0.35)
        case .none:     return .clear
        }
    }
    @ViewBuilder private var strokeOverlay: some View {
        if state == .none { Circle().stroke(Color(white: 0.4), lineWidth: 1) }
    }
}

private struct BadgeView: View {
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

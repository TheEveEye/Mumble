import SwiftUI

struct TalkingUISnapshot: Equatable {
    let entries: [TalkingUIVisibleEntry]
    let fontSizePercentage: Int
    let automaticallyExpandsWidth: Bool
    let columnCount: Int

    var fontScale: Double {
        Double(fontSizePercentage) / 100
    }

    var estimatedDisplayRowCount: Int {
        entries.count + sections.count
    }

    func preferredAutoExpandedColumnCount(forContentHeight contentHeight: CGFloat) -> Int {
        guard automaticallyExpandsWidth, estimatedDisplayRowCount > 0 else {
            return 1
        }

        let rowHeight = max(20, 25 * fontScale)
        let usableHeight = max(rowHeight, contentHeight - 24)
        let rowsPerColumn = max(1, Int(floor(usableHeight / rowHeight)))
        return min(4, max(1, Int(ceil(Double(estimatedDisplayRowCount) / Double(rowsPerColumn)))))
    }

    func withColumnCount(_ columnCount: Int) -> TalkingUISnapshot {
        TalkingUISnapshot(
            entries: entries,
            fontSizePercentage: fontSizePercentage,
            automaticallyExpandsWidth: automaticallyExpandsWidth,
            columnCount: max(1, columnCount)
        )
    }

    var sections: [TalkingUIChannelSection] {
        let groupedEntries = Dictionary(grouping: entries) { entry in
            entry.channel?.id
        }

        return groupedEntries.map { channelID, entries in
            TalkingUIChannelSection(
                id: channelID,
                title: entries.first?.channel?.name ?? "Unknown Channel",
                entries: entries.sorted(by: Self.entrySortComparator)
            )
        }
        .sorted(by: Self.sectionSortComparator)
    }

    private static let entrySortComparator: (TalkingUIVisibleEntry, TalkingUIVisibleEntry) -> Bool = { lhs, rhs in
        let comparison = lhs.user.name.localizedStandardCompare(rhs.user.name)
        if comparison == .orderedSame {
            return lhs.user.id < rhs.user.id
        }

        return comparison == .orderedAscending
    }

    private static let sectionSortComparator: (TalkingUIChannelSection, TalkingUIChannelSection) -> Bool = { lhs, rhs in
        if lhs.id == nil {
            return false
        }

        if rhs.id == nil {
            return true
        }

        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison == .orderedSame {
            return (lhs.id ?? 0) < (rhs.id ?? 0)
        }

        return comparison == .orderedAscending
    }
}

struct TalkingUIView: View {
    let snapshot: TalkingUISnapshot

    private var scaledBodyFont: Font {
        .system(size: 13 * fontScale)
    }

    private var scaledCaptionFont: Font {
        .system(size: 11 * fontScale, weight: .semibold)
    }

    private var fontScale: Double {
        snapshot.fontScale
    }

    private var columns: [TalkingUIColumn] {
        TalkingUIColumn.makeColumns(
            from: snapshot.sections,
            columnCount: snapshot.columnCount
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if snapshot.sections.isEmpty {
                ContentUnavailableView(
                    "No Active Talkers",
                    systemImage: "person.3.fill"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(columns) { column in
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(column.sections) { section in
                                    TalkingUISectionView(
                                        section: section,
                                        bodyFont: scaledBodyFont,
                                        captionFont: scaledCaptionFont
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 260, idealWidth: 320, minHeight: 160, idealHeight: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TalkingUIChannelSection: Identifiable, Equatable {
    let id: UInt32?
    let title: String
    let entries: [TalkingUIVisibleEntry]
}

private struct TalkingUIColumn: Identifiable, Equatable {
    let id: Int
    let sections: [TalkingUIChannelSection]

    static func makeColumns(
        from sections: [TalkingUIChannelSection],
        columnCount: Int
    ) -> [TalkingUIColumn] {
        let columnCount = max(1, columnCount)
        guard columnCount > 1, sections.isEmpty == false else {
            return [TalkingUIColumn(id: 0, sections: sections)]
        }

        let targetRowsPerColumn = max(
            1,
            Int(ceil(Double(sections.reduce(0) { $0 + 1 + $1.entries.count }) / Double(columnCount)))
        )
        var columns: [TalkingUIColumn] = []
        var currentSections: [TalkingUIChannelSection] = []
        var currentRows = 0

        func appendCurrentColumnIfNeeded() {
            guard currentSections.isEmpty == false else {
                return
            }

            columns.append(TalkingUIColumn(id: columns.count, sections: currentSections))
            currentSections = []
            currentRows = 0
        }

        for section in sections {
            var remainingEntries = section.entries

            while remainingEntries.isEmpty == false {
                let availableRows = max(1, targetRowsPerColumn - currentRows - 1)
                if currentRows > 0, availableRows <= 0 {
                    appendCurrentColumnIfNeeded()
                    continue
                }

                let entriesForColumn = Array(remainingEntries.prefix(availableRows))
                remainingEntries.removeFirst(entriesForColumn.count)
                currentSections.append(
                    TalkingUIChannelSection(
                        id: section.id,
                        title: section.title,
                        entries: entriesForColumn
                    )
                )
                currentRows += 1 + entriesForColumn.count

                if remainingEntries.isEmpty == false {
                    appendCurrentColumnIfNeeded()
                }
            }

            if section.entries.isEmpty {
                if currentRows > 0, currentRows + 1 > targetRowsPerColumn {
                    appendCurrentColumnIfNeeded()
                }

                currentSections.append(section)
                currentRows += 1
            }
        }

        appendCurrentColumnIfNeeded()
        return columns
    }
}

private struct TalkingUISectionView: View {
    let section: TalkingUIChannelSection
    let bodyFont: Font
    let captionFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VStack(spacing: 2) {
                ForEach(section.entries) { entry in
                    TalkingUIUserRow(entry: entry, bodyFont: bodyFont)
                }
            }
        }
    }
}

private struct TalkingUIUserRow: View {
    let entry: TalkingUIVisibleEntry
    let bodyFont: Font

    var body: some View {
        HStack(spacing: 8) {
            indicatorImage
                .foregroundStyle(entry.talkState.talkingUIColor)
                .help(entry.talkState.talkingUIHelpText)
                .frame(width: 14)

            Text(entry.user.name)
                .font(entry.isCurrentSession ? bodyFont.bold() : bodyFont)
                .foregroundStyle(entry.isActivelyTalking ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ForEach(entry.user.talkingUIStatusBadges) { badge in
                    Image(systemName: badge.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .help(badge.helpText)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(entry.isCurrentSession ? Color.accentColor.opacity(0.12) : .clear)
        )
    }

    @ViewBuilder
    private var indicatorImage: some View {
        switch entry.talkState {
        case .passive:
            Image(systemName: "person.fill")
                .font(.system(size: 12, weight: .semibold))
        case .talking, .whispering, .shouting, .channelListening:
            Image("person.radiowaves.left.and.right.fill")
                .renderingMode(.template)
                .font(.system(size: 12, weight: .semibold))
        }
    }
}

private struct TalkingUIStatusBadge: Identifiable, Hashable {
    let id: String
    let systemImage: String
    let color: Color
    let helpText: String
}

private extension MumbleUserTalkState {
    var talkingUIColor: Color {
        switch self {
        case .passive:
            return .green
        case .talking:
            return .blue
        case .shouting:
            return .blue
        case .whispering:
            return .yellow
        case .channelListening:
            return .gray
        }
    }

    var talkingUIHelpText: String {
        switch self {
        case .passive:
            return "Recently talked"
        case .talking:
            return "Talking"
        case .shouting:
            return "Shouting"
        case .whispering:
            return "Whispering"
        case .channelListening:
            return "Talking via channel listener"
        }
    }
}

private extension MumbleUser {
    var talkingUIStatusBadges: [TalkingUIStatusBadge] {
        var badges: [TalkingUIStatusBadge] = []

        if isServerMuted || isServerDeafened {
            badges.append(
                TalkingUIStatusBadge(
                    id: "server-muted",
                    systemImage: "mic.slash.fill",
                    color: .blue,
                    helpText: "Muted by server"
                )
            )
        }

        if isSuppressed {
            badges.append(
                TalkingUIStatusBadge(
                    id: "suppressed",
                    systemImage: "mic.slash.fill",
                    color: .green,
                    helpText: "Suppressed in channel"
                )
            )
        }

        if isSelfMuted || isSelfDeafened {
            badges.append(
                TalkingUIStatusBadge(
                    id: "self-muted",
                    systemImage: "mic.slash.fill",
                    color: .red,
                    helpText: "Self-muted"
                )
            )
        }

        if isServerDeafened {
            badges.append(
                TalkingUIStatusBadge(
                    id: "server-deafened",
                    systemImage: "speaker.slash.fill",
                    color: .blue,
                    helpText: "Deafened by server"
                )
            )
        }

        if isSelfDeafened {
            badges.append(
                TalkingUIStatusBadge(
                    id: "self-deafened",
                    systemImage: "speaker.slash.fill",
                    color: .red,
                    helpText: "Self-deafened"
                )
            )
        }

        if isAuthenticated {
            badges.append(
                TalkingUIStatusBadge(
                    id: "authenticated",
                    systemImage: "checkmark",
                    color: .yellow,
                    helpText: "Authenticated"
                )
            )
        }

        return badges
    }
}

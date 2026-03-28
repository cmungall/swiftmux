import SwiftUI

struct CommandPaletteView: View {
    let sessions: [SessionInfo]
    let onSelect: (SessionInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFieldFocused: Bool
    @State private var query = ""
    @State private var highlightedIndex = 0

    private var filteredSessions: [SessionInfo] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            return sessions
        }

        let loweredQuery = trimmedQuery.lowercased()

        return sessions
            .compactMap { session -> (SessionInfo, Int)? in
                guard let score = bestScore(for: loweredQuery, session: session) else {
                    return nil
                }

                return (session, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }

                return SessionInfo.sort(lhs.0, rhs.0)
            }
            .map(\.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Jump to tmux session")
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                TextField("Search sessions, repos, branches, or descriptions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(AppTheme.windowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .focused($searchFieldFocused)
                    .onSubmit {
                        guard filteredSessions.indices.contains(highlightedIndex) else {
                            return
                        }

                        choose(filteredSessions[highlightedIndex])
                    }
            }
            .padding(20)

            Divider()
                .overlay(AppTheme.border)

            if filteredSessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No matching sessions")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Try a repo name, branch, process, or description.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundColor(AppTheme.mutedText)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                            Button {
                                choose(session)
                            } label: {
                                CommandPaletteRow(
                                    session: session,
                                    isHighlighted: index == highlightedIndex
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
                .overlay(AppTheme.border)

            HStack {
                Text("Enter to switch")
                Text("Esc to dismiss")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(AppTheme.mutedText)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 660, height: 520)
        .background(AppTheme.panelBackground)
        .onAppear {
            searchFieldFocused = true
        }
        .onChange(of: query) { _ in
            highlightedIndex = 0
        }
        .onMoveCommand { direction in
            guard !filteredSessions.isEmpty else {
                return
            }

            switch direction {
            case .down:
                highlightedIndex = min(highlightedIndex + 1, filteredSessions.count - 1)
            case .up:
                highlightedIndex = max(highlightedIndex - 1, 0)
            default:
                break
            }
        }
        .onExitCommand {
            dismiss()
        }
    }

    private func choose(_ session: SessionInfo) {
        onSelect(session)
        dismiss()
    }

    private func bestScore(for query: String, session: SessionInfo) -> Int? {
        session.searchTokens.compactMap { fuzzyScore(query: query, in: $0) }.max()
    }

    private func fuzzyScore(query: String, in candidate: String) -> Int? {
        if candidate.hasPrefix(query) {
            return 10_000 - candidate.count
        }

        if let range = candidate.range(of: query) {
            let distance = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return 8_000 - distance
        }

        var queryIndex = query.startIndex
        var previousMatchIndex: Int?
        var score = 0

        for (index, character) in candidate.enumerated() {
            guard queryIndex < query.endIndex else {
                break
            }

            if character == query[queryIndex] {
                score += 10
                if let previousMatchIndex, previousMatchIndex + 1 == index {
                    score += 6
                }
                previousMatchIndex = index
                query.formIndex(after: &queryIndex)
            }
        }

        guard queryIndex == query.endIndex else {
            return nil
        }

        return score
    }
}

private struct CommandPaletteRow: View {
    let session: SessionInfo
    let isHighlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(session.status.color)
                .frame(width: 8, height: 8)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))

                    Spacer(minLength: 10)

                    Text(session.process)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(AppTheme.mutedText)
                }

                Text(session.detailSummary)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(AppTheme.mutedText)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    CommandPaletteTag(text: session.repoGroupName)
                    if let branch = session.branchName {
                        CommandPaletteTag(text: branch)
                    }
                    CommandPaletteTag(text: session.status.label)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? AppTheme.elevatedBackground : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHighlighted ? AppTheme.border : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct CommandPaletteTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(AppTheme.mutedText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppTheme.windowBackground)
            .clipShape(Capsule())
    }
}

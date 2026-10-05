import SwiftUI

/// The search field's suggestions (`.searchSuggestions`, V-SEARCH.E06/N14–N17):
/// - a link: what can be done with it (the link row) — never a text search;
/// - a filter word being typed: library values with their counts; choosing one makes a token;
/// - a partly typed filter word (`gen`): the filter words it starts;
/// - the empty field: recent searches and the filter words this place understands.
struct SearchSuggestionList: View {
    let model: ToolbarSearchModel

    var body: some View {
        if let link = model.link {
            LinkSuggestionRows(link: link, lookup: model.linkLookup) {
                model.openLink(link)
            }
        } else if let clause = model.trailingClause, model.offeredKinds.contains(clause.kind) {
            if clause == model.suggestionsClause, !model.valueSuggestions.isEmpty {
                Section("\(clause.kind.prefix) \(clause.partialValue)") {
                    ForEach(model.valueSuggestions) { suggestion in
                        HStack {
                            Text(suggestion.token.valueText)
                            Spacer()
                            Text(suggestion.count, format: .number)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .searchCompletion(suggestion.token)
                    }
                }
            }
        } else if !model.keywordCompletions.isEmpty {
            Section("Filters") {
                ForEach(model.keywordCompletions, id: \.kind) { item in
                    filterRow(item.kind)
                        .searchCompletion(item.completion)
                }
            }
        } else if !model.hasInput {
            if !model.recentSearches.isEmpty {
                Section("Recent searches") {
                    ForEach(model.recentSearches) { recent in
                        Button {
                            model.apply(recent)
                        } label: {
                            Label(recent.filter.displayText, systemImage: "clock")
                        }
                    }
                }
            }
            if !model.offeredKinds.isEmpty {
                Section("Filters") {
                    ForEach(model.offeredKinds, id: \.self) { kind in
                        filterRow(kind)
                            .searchCompletion("\(kind.prefix) ")
                    }
                }
            }
        }
    }

    private func filterRow(_ kind: SearchTokenKind) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(kind.prefix)
            Text(kind.hint)
                .foregroundStyle(.secondary)
        }
    }
}

/// The rows a pasted link offers (`search.html` V-SEARCH.N14/N15): the action as the first
/// row (Return takes it), or what is in the way.
struct LinkSuggestionRows: View {
    let link: LinkSuggestion
    let lookup: LinkLookup?
    let perform: () -> Void

    var body: some View {
        Section(link.header) {
            switch link {
            case .unsupported(_, let url):
                Label(LinkSuggestion.unsupportedLine, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                if let target = URL(string: url) {
                    Button {
                        NSWorkspace.shared.open(target)
                    } label: {
                        Label(LinkSuggestion.openInBrowser, systemImage: "globe")
                    }
                }
            case .track, .playlist:
                if lookup == nil {
                    Label(LinkSuggestion.lookingUp, systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                if lookup?.libraryTrackID != nil, case .track = link {
                    Button(action: perform) {
                        Label {
                            Text(LinkSuggestion.inLibraryTitle(lookup?.metadata?.title ?? LinkSuggestion.shortURL(link.url)))
                            Text(LinkSuggestion.inLibraryDetail)
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                } else {
                    Button(action: perform) {
                        Label {
                            Text(link.actionTitle(lookup?.metadata))
                            Text(link.detail(lookup?.metadata))
                        } icon: {
                            Image(systemName: isPlaylist ? "music.note.list" : "arrow.down.circle")
                        }
                    }
                }
            }
        }
    }

    private var isPlaylist: Bool {
        if case .playlist = link { return true }
        return false
    }
}

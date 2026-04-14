import Foundation

struct SavedServerSection: Identifiable {
    let id: String
    let title: String
    let servers: [SavedServer]
}

enum SavedServerPresentation {
    static func sorted(_ servers: [SavedServer]) -> [SavedServer] {
        servers.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }

            let lhsName = lhs.displayName.localizedLowercase
            let rhsName = rhs.displayName.localizedLowercase

            if lhsName != rhsName {
                return lhsName < rhsName
            }

            return lhs.host.localizedLowercase < rhs.host.localizedLowercase
        }
    }

    static func sections(from servers: [SavedServer]) -> [SavedServerSection] {
        let sortedServers = sorted(servers)
        let favorites = sortedServers.filter(\.isFavorite)
        let regularServers = sortedServers.filter { !$0.isFavorite }

        var sections: [SavedServerSection] = []

        if !favorites.isEmpty {
            sections.append(
                SavedServerSection(
                    id: "favorites",
                    title: "Favorite",
                    servers: favorites
                )
            )
        }

        let groupedServers = Dictionary(grouping: regularServers) { $0.folderDisplayName }

        for title in groupedServers.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let groupedServers = groupedServers[title] else {
                continue
            }

            sections.append(
                SavedServerSection(
                    id: title,
                    title: title,
                    servers: groupedServers
                )
            )
        }

        return sections
    }
}

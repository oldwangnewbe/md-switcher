import Foundation

struct ArtworkCollection: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    var choices: [Int: Int]

    // A zero value is membership without an artwork override.
    static let cardOnly = 0

    static let presets: [ArtworkCollection] = [
        .init(id: "sky-striker", name: "闪刀姬", choices: [
            13670: 26077389, 14829: 37351134, 13668: 63288574, 13669: 90673289,
            13763: 8491309, 13671: 63166096, 17034: 9726841, 13675: 98338153,
        ]),
        .init(id: "branded", name: "烙印", choices: [
            15245: 68468460, 16195: 62962631, 16493: 55273561,
            17069: 44146296, 17767: 95515790, 15239: 60303689,
        ]),
        .init(id: "dark-magician", name: "黑魔导", choices: [
            4041: 46986418, 4766: 38033123, 5628: 98502114, 11151: 43892409,
            12456: 47222537, 14908: 59514117, 14952: 37818795, 22692: 41350418,
        ]),
    ]

    private static let key = "artworkCollections"

    static func load(from defaults: UserDefaults = .standard) -> [ArtworkCollection] {
        let saved = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([ArtworkCollection].self, from: $0)
        } ?? []
        return presets.map { preset in saved.first(where: { $0.id == preset.id }) ?? preset }
            + saved.filter { collection in !presets.contains(where: { $0.id == collection.id }) }
    }

    static func save(_ collections: [ArtworkCollection], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(collections) { defaults.set(data, forKey: key) }
    }

    func cards(in catalog: CardSearchCatalog) -> [Entry] {
        choices.keys.sorted().compactMap { cid in
            guard let variantID = choices[cid] else { return nil }
            return Entry(id: cid, card: catalog.card(cid: cid), variantID: variantID)
        }
    }

    struct Entry: Identifiable {
        let id: Int
        let card: SearchCard?
        let variantID: Int

        var hasArtworkChoice: Bool { variantID != ArtworkCollection.cardOnly }
        var variant: SearchCard.Variant? { card?.variants.first { $0.id == variantID } }
    }
}

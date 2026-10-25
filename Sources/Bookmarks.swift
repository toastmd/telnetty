import Foundation

struct Bookmark: Codable, Equatable {
    var name: String
    var host: String
    var port: Int
}

enum BookmarkStore {
    private static let key = "bookmarks.v1"

    static func load() -> [Bookmark] {
        if let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Bookmark].self, from: data) {
            return list
        }
        // first run: a couple of public examples (they may be offline when you read this)
        return [
            Bookmark(name: "ASCII Star Wars", host: "towel.blinkenlights.nl", port: 23),
            Bookmark(name: "Aardwolf MUD", host: "aardmud.org", port: 4000),
        ]
    }

    static func save(_ list: [Bookmark]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

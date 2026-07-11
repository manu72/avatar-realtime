import UIKit

enum Mouth: CaseIterable { case closed, half, open }

/// Same outfits and backgrounds as the web app (assets copied into the
/// bundle; the web assets stay untouched). Swimsuit reuses the half-open
/// frame for "open", exactly like app.js does.
struct Outfit: Identifiable, Hashable {
    let name: String        // chip label, with emoji
    let clean: String       // emoji-free name sent in scene updates
    let sprites: [Mouth: String]

    var id: String { name }

    func sprite(for mouth: Mouth) -> String { sprites[mouth] ?? sprites[.closed]! }

    static let all: [Outfit] = [
        Outfit(name: "Seifuku 🎀", clean: "Seifuku",
               sprites: [.closed: "uniform_closed", .half: "uniform_half", .open: "uniform_open"]),
        Outfit(name: "Sundress 🌿", clean: "Sundress",
               sprites: [.closed: "casual_closed", .half: "casual_half", .open: "casual_open"]),
        Outfit(name: "Swimsuit 🩱", clean: "Swimsuit",
               sprites: [.closed: "swim2_closed", .half: "swim2_half", .open: "swim2_half"]),
        Outfit(name: "Gym 🏃‍♀️", clean: "Gym",
               sprites: [.closed: "gym_closed", .half: "gym_half", .open: "gym_open"]),
        Outfit(name: "Nightgown 🌙", clean: "Nightgown",
               sprites: [.closed: "night_closed", .half: "night_half", .open: "night_open"]),
    ]
}

struct Backdrop: Identifiable, Hashable {
    let name: String
    let clean: String
    let resource: String

    var id: String { name }

    static let all: [Backdrop] = [
        Backdrop(name: "Bedroom 🛏", clean: "Bedroom", resource: "bedroom"),
        Backdrop(name: "Sakura 🌸", clean: "Sakura", resource: "sakura"),
        Backdrop(name: "Beach 🏖", clean: "Beach", resource: "beach"),
        Backdrop(name: "Fuji 🗻", clean: "Fuji", resource: "fuji"),
        Backdrop(name: "Onsen ♨️", clean: "Onsen", resource: "onsen"),
        Backdrop(name: "Gym 🏋️", clean: "Gym", resource: "gym"),
    ]
}

/// Bundle .webp loader with a cache so mouth swaps never decode or flicker.
enum SpriteLoader {
    private static var cache: [String: UIImage] = [:]

    static func image(_ name: String) -> UIImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp"),
              let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        cache[name] = img
        return img
    }
}

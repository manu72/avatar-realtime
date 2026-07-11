import SwiftUI

/// Three stacked mouth frames with opacity toggles — the sprites stay decoded
/// and in the view tree, so switching frames never flickers (same trick as
/// the preloaded <img> elements in the web app).
struct AvatarView: View {
    let outfit: Outfit
    let mouth: Mouth

    var body: some View {
        ZStack {
            ForEach(Mouth.allCases, id: \.self) { state in
                if let img = SpriteLoader.image(outfit.sprite(for: state)) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .opacity(mouth == state ? 1 : 0)
                }
            }
        }
        .accessibilityLabel("Sakura")
    }
}

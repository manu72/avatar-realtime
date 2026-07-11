import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: SessionViewModel
    @State private var draft = ""
    @State private var showMemory = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            avatar
            VStack(spacing: 8) {
                header
                chipRow(Outfit.all, selected: vm.outfit.id) { vm.setOutfit($0) }
                chipRow(Backdrop.all, selected: vm.backdrop.id) { vm.setBackdrop($0) }
                Spacer(minLength: 0)
                transcript
                inputBar
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if !vm.sessionStarted { startOverlay }
        }
        // The backdrop image lives in .background, NOT as a ZStack child: a
        // resizable().scaledToFill() image reports its OVERFLOWING size (the
        // 1344×752 art becomes ~1560pt wide on a 402pt screen), and as a
        // sibling it inflates the ZStack's bounds, pushing every full-width
        // child (header, chips, input bar) off the visible screen. A
        // background layer can never influence layout.
        .background { background }
        .sheet(isPresented: $showMemory) { MemoryView().environmentObject(vm) }
        .alert("Audio couldn't start", isPresented: Binding(
            get: { vm.audioError != nil },
            set: { if !$0 { vm.audioError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.audioError ?? "")
        }
        .alert("Gemini API key missing", isPresented: $vm.apiKeyMissing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy ios/Config/Secrets.example.xcconfig to Secrets.xcconfig, add your key, and rebuild.")
        }
    }

    // MARK: - Layers

    private var background: some View {
        Group {
            if let img = SpriteLoader.image(vm.backdrop.resource) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.pink.opacity(0.3), .purple.opacity(0.2)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var avatar: some View {
        AvatarView(outfit: vm.outfit, mouth: vm.mouth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 150)
            .ignoresSafeArea(.keyboard)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack {
            Text(vm.statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Button {
                showMemory = true
            } label: {
                Image(systemName: "brain.head.profile")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.pink)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var statusColor: Color {
        switch vm.statusKind {
        case .idle: .secondary
        case .ok: .green
        case .talk: .pink
        case .error: .red
        }
    }

    private func chipRow<Item: Identifiable & Hashable>(
        _ items: [Item], selected: Item.ID, pick: @escaping (Item) -> Void
    ) -> some View where Item.ID == String {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    let name = (item as? Outfit)?.name ?? (item as? Backdrop)?.name ?? ""
                    Button { pick(item) } label: {
                        Text(name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(item.id == selected ? Color.pink.opacity(0.85) : Color.white.opacity(0.65),
                                        in: Capsule())
                            .foregroundStyle(item.id == selected ? .white : .black)
                    }
                }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(vm.bubbles) { bubble in
                        Text(bubble.text)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(bubble.role == .you ? Color.pink.opacity(0.9) : Color.white.opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(bubble.role == .you ? .white : .black)
                            .frame(maxWidth: .infinity,
                                   alignment: bubble.role == .you ? .trailing : .leading)
                            .id(bubble.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 170)
            .onChange(of: vm.bubbles.last?.text) {
                if let id = vm.bubbles.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("say something…", text: $draft)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.pink, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)

            Button(action: vm.toggleMic) {
                Image(systemName: vm.micLive ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(vm.micLive ? Color.green : Color.gray, in: Circle())
            }
        }
    }

    private func send() {
        vm.sendText(draft)
        draft = ""
    }

    private var startOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("🌸").font(.system(size: 56))
                Text("Tap to meet Sakura")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("voice chat starts right away")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.startSession() }
    }
}

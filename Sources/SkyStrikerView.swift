import SwiftUI

private final class SkyStrikerDraft: ObservableObject {
    @Published var pack: SkyStrikerPack?
    @Published var selection: [String: Int] = [:]
    @Published var loadError: String?
    @Published var submitted = false
}

struct SkyStrikerView: View {
    @ObservedObject var model: SwitcherModel
    @StateObject private var draft = SkyStrikerDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("闪刀异画").font(.title2.bold())
            if let account = model.selected, model.canManageMods || model.busy {
                Text("应用到 \(model.aliases[String(account.id)] ?? account.displayName) · 普通版卡图")
                    .foregroundStyle(.secondary)
            } else {
                Text("请先选择一个已经准备好游戏资源的账号。").foregroundStyle(.secondary)
            }
            if let pack = draft.pack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                        ForEach(pack.cards) { card in
                            cardTile(card, pack: pack)
                        }
                    }
                    .padding(1)
                }
            } else {
                Spacer()
            }
            if let loadError = draft.loadError {
                Text(loadError).font(.callout).foregroundStyle(.orange)
            }
            if draft.submitted {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout)
                        .foregroundStyle(model.error ? Color.orange : .secondary)
                }
            }
            HStack {
                Button("选整套异画") {
                    draft.selection = draft.pack?.cards.reduce(into: [:]) { result, card in
                        result[card.path] = card.variants.first?.id
                    } ?? [:]
                }
                .disabled(model.busy || draft.pack == nil)
                Button("选整套原画") { draft.selection = [:] }
                    .disabled(model.busy || draft.pack == nil)
                Button("恢复原卡图") { apply([:]) }
                    .disabled(!model.canManageMods || draft.pack == nil)
                Spacer()
                Button("应用到所选账号") { apply(draft.selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canManageMods || draft.pack == nil)
                Button("应用到所有账号") {
                    apply(draft.selection, all: true)
                }
                .disabled(!model.canApplyArtworkToAll || draft.pack == nil)
            }
        }
        .padding(22)
        .onAppear {
            do {
                draft.pack = try SkyStrikerPack.bundled()
                draft.selection = try model.artworkSelections()
            } catch {
                draft.loadError = error.localizedDescription
            }
        }
    }

    private func apply(_ selections: [String: Int], all: Bool = false) {
        guard let pack = draft.pack else { return }
        draft.submitted = true
        model.updateSkyStriker(selections, pack: pack, all: all) { draft.selection = selections }
    }

    private func cardTile(_ card: SkyStrikerPack.Card, pack: SkyStrikerPack) -> some View {
        let id = draft.selection[card.path]
        let preview = NSImage(contentsOf: id.map(pack.preview) ?? pack.originalPreview(for: card))
        return VStack(spacing: 7) {
            Text(card.name).font(.callout.bold()).lineLimit(1)
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 102, height: 102)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text(id == nil ? "原卡图预览" : "所选异画预览"))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(width: 102, height: 102)
                    .accessibilityLabel(id == nil ? "缺少原卡图预览" : "缺少异画预览")
            }
            Picker(card.name, selection: Binding(
                get: { draft.selection[card.path] },
                set: { draft.selection[card.path] = $0 }
            )) {
                Text("原卡图").tag(nil as Int?)
                ForEach(Array(card.variants.enumerated()), id: \.element.id) { index, variant in
                    Text("异画 \(index + 1)").tag(Optional(variant.id))
                }
            }
            .labelsHidden()
            .disabled(model.busy)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }
}

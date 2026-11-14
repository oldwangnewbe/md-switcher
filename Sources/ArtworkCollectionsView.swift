import SwiftUI

final class ArtworkCollectionsDraft: ObservableObject {
    @Published var selected = ArtworkCollection.presets[0].id
    @Published var catalog: CardSearchCatalog?
    @Published var loading = true
    @Published var error: String?
    @Published var newName = ""
    @Published var creating = false
    @Published var submitted = false
    @Published var reload = 0
}

struct ArtworkCollectionsView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var draft: ArtworkCollectionsDraft
    let openSearch: () -> Void

    private var collection: ArtworkCollection? {
        model.artworkCollections.first { $0.id == draft.selected }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("异画合集").font(.title2.bold())
                Spacer()
                Button("去卡片搜索添加", action: openSearch)
            }
            .disabled(model.busy)
            HStack(alignment: .top, spacing: 14) {
                sidebar
                Divider()
                if draft.loading {
                    ProgressView("正在读取本机卡库…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let collection, let catalog = draft.catalog {
                    collectionContents(collection, catalog: catalog)
                } else {
                    VStack(spacing: 8) {
                        Text(draft.error ?? "请选择一个合集。").foregroundStyle(.secondary)
                        Button("重试读取卡库") { draft.reload += 1 }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if draft.submitted {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).foregroundStyle(model.error ? Color.orange : .secondary)
                }
            } else if let error = draft.error, draft.catalog != nil {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            footer.disabled(draft.loading || draft.catalog == nil)
        }
        .padding(22)
        .task(id: draft.reload) { await load() }
        .alert("新建异画合集", isPresented: $draft.creating) {
            TextField("合集名称", text: $draft.newName)
            Button("取消", role: .cancel) {}
            Button("新建", action: create)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.artworkCollections) { collection in
                        Button {
                            draft.selected = collection.id
                            draft.submitted = false
                        } label: {
                            HStack {
                                Text(collection.name).lineLimit(1)
                                Spacer()
                                Text("\(collection.choices.count) 张").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(7)
                            .background(draft.selected == collection.id ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                draft.newName = ""
                draft.creating = true
            } label: { Label("新建合集", systemImage: "plus") }
        }
        .frame(width: 175)
        .disabled(model.busy)
    }

    private func collectionContents(_ collection: ArtworkCollection, catalog: CardSearchCatalog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(collection.name).font(.headline)
            if collection.choices.isEmpty {
                Text("在卡片搜索选中卡片，再点「加入合集」。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(collection.cards(in: catalog)) { entry in
                            cardRow(entry, collection: collection, catalog: catalog)
                        }
                    }
                }
                .disabled(model.busy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardRow(_ entry: ArtworkCollection.Entry, collection: ArtworkCollection,
                         catalog: CardSearchCatalog) -> some View {
        HStack(spacing: 9) {
            if let variant = entry.variant,
               let image = NSImage(contentsOf: catalog.preview(variant)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 54, height: 54)
                    .accessibilityLabel("异画预览")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.card?.name ?? "编号 \(entry.id)").font(.body.weight(.medium))
                if entry.hasArtworkChoice && entry.card?.path == nil {
                    Text("目标卡图暂不可用").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let card = entry.card, card.path != nil, !card.variants.isEmpty {
                Picker(card.name, selection: Binding(
                    get: { entry.variantID },
                    set: { model.setArtworkCollectionChoice(collection.id, cid: entry.id, variant: $0) }
                )) {
                    Text("仅收藏").tag(ArtworkCollection.cardOnly)
                    if entry.hasArtworkChoice && entry.variant == nil { Text("原选异画已找不到").tag(entry.variantID) }
                    ForEach(Array(card.variants.enumerated()), id: \.element.id) { index, variant in
                        Text("\(variant.overFrame == nil ? "异画" : "超框异画") \(index + 1)").tag(variant.id)
                    }
                }
                .labelsHidden()
                .frame(width: 128)
            } else if !entry.hasArtworkChoice {
                Text("仅收藏").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                model.setArtworkCollectionChoice(collection.id, cid: entry.id, variant: nil)
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("从合集移除\(entry.card?.name ?? String(entry.id))")
        }
        .padding(7)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
    }

    private var footer: some View {
        let entries = (draft.catalog.flatMap { catalog in collection?.cards(in: catalog) } ?? []).filter(\.hasArtworkChoice)
        let canRestore = !entries.isEmpty && entries.allSatisfy { $0.card?.path != nil }
        let canApply = canRestore && entries.allSatisfy { $0.variant != nil }
        return HStack {
            if let account = model.selected {
                Text(model.aliases[String(account.id)] ?? account.displayName).foregroundStyle(.secondary)
            }
            Menu("恢复合集原画") {
                Button("所选账号") { apply(restore: true, all: false) }.disabled(!model.canManageMods)
                Button("所有账号") { apply(restore: true, all: true) }.disabled(!model.canApplyArtworkToAll)
            }
            .disabled(!canRestore || model.busy)
            Spacer()
            Button("应用到所选账号") { apply(all: false) }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply || !model.canManageMods)
            Button("应用到所有账号") { apply(all: true) }
                .disabled(!canApply || !model.canApplyArtworkToAll)
        }
    }

    private func load() async {
        draft.loading = true
        draft.error = nil
        draft.submitted = false
        do {
            let catalog = try await model.loadCardSearch()
            try Task.checkCancellation()
            draft.catalog = catalog
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            draft.catalog = nil
            draft.error = error.localizedDescription
        }
        draft.loading = false
    }

    private func create() {
        do {
            draft.selected = try model.createArtworkCollection(draft.newName)
            draft.error = nil
            draft.submitted = false
        } catch {
            draft.error = error.localizedDescription
        }
    }

    private func apply(restore: Bool = false, all: Bool) {
        guard let collection, let catalog = draft.catalog else { return }
        model.applyArtworkCollection(collection, catalog: catalog, restore: restore, all: all) {
            draft.submitted = true
        }
    }
}

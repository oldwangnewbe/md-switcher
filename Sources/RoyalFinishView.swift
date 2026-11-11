import SwiftUI

final class RoyalFinishDraft: ObservableObject {
    enum Mode: String, CaseIterable {
        case search = "搜卡片"
        case collection = "按合集"
        case enabled = "已开启"
    }

    @Published var mode = Mode.search
    @Published var query = ""
    @Published var results = CardSearchCatalog.Results()
    @Published var collectionID = ArtworkCollection.presets[0].id
    @Published var catalog: CardSearchCatalog?
    @Published var loading = true
    @Published var error: String?
    @Published var reload = 0
}

struct RoyalFinishView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var draft: RoyalFinishDraft

    private var collection: ArtworkCollection? {
        model.artworkCollections.first { $0.id == draft.collectionID }
    }

    private var collectionCards: [SearchCard] {
        guard let catalog = draft.catalog else { return [] }
        return collection?.cards(in: catalog).compactMap(\.card) ?? []
    }

    private var enabledCards: [SearchCard] {
        guard let catalog = draft.catalog else { return [] }
        return model.selectedRoyalFinishCardIDs.compactMap(catalog.card(cid:)).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("动态镜碎").font(.title2.bold())
                Spacer()
                if let account = model.selected {
                    Text(model.aliases[String(account.id)] ?? account.displayName)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("查看", selection: $draft.mode) {
                ForEach(RoyalFinishDraft.Mode.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                if draft.loading {
                    ProgressView("正在读取本机卡库…")
                } else if let error = draft.error {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.orange)
                        Button("重试读取") { draft.reload += 1 }
                    }
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            Text("换号器运行时，从 Steam 启动游戏也会自动加载。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(22)
        .task(id: draft.reload) { await load() }
        .onChange(of: draft.query) { _ in refreshResults() }
    }

    @ViewBuilder
    private var content: some View {
        switch draft.mode {
        case .search:
            VStack(alignment: .leading, spacing: 10) {
                TextField("搜索卡名、系列名或卡片编号", text: $draft.query)
                    .textFieldStyle(.roundedBorder)
                cardList(draft.results.cards.filter { !$0.royalCardIDs.isEmpty },
                         empty: draft.query.isEmpty ? "输入卡名、系列名或卡片编号。" : "没有找到匹配的《大师决斗》卡片。")
            }
        case .collection:
            let ids = Set(collectionCards.flatMap(\.royalCardIDs))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("合集", selection: $draft.collectionID) {
                        ForEach(model.artworkCollections) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    actions(ids, label: "整组设置")
                }
                cardList(collectionCards, empty: "这个合集暂时没有可设置的卡片。")
            }
        case .enabled:
            VStack(alignment: .leading, spacing: 10) {
                if !model.selectedRoyalFinishCardIDs.isEmpty {
                    HStack {
                        Text("当前账号").font(.headline)
                        Spacer()
                        Button("全部关闭") {
                            model.setRoyalFinish(model.selectedRoyalFinishCardIDs, enabled: false)
                        }
                    }
                }
                cardList(enabledCards, empty: "当前账号还没有显示动态镜碎的卡片。")
            }
        }
    }

    private func cardList(_ cards: [SearchCard], empty: String) -> some View {
        Group {
            if cards.isEmpty {
                Text(empty).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(cards) { card in
                            HStack(spacing: 10) {
                                CardThumbnail(url: draft.catalog?.thumbnailURL(for: card))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.name).fontWeight(.medium)
                                    if let name = card.proName, name != card.name {
                                        Text(name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                let ids = card.royalCardIDs
                                let enabled = model.hasRoyalFinish(for: ids)
                                actions(ids, label: enabled ? "已开启" : "未开启")
                                    .accessibilityLabel("设置\(card.name)的动态镜碎")
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func actions(_ ids: Set<Int>, label: String) -> some View {
        Menu(label) {
            Button("为所选账号开启") { model.setRoyalFinish(ids, enabled: true) }
            Button("为所选账号关闭") { model.setRoyalFinish(ids, enabled: false) }
            Divider()
            Button("为所有账号开启") { model.setRoyalFinish(ids, enabled: true, all: true) }
            Button("为所有账号关闭") { model.setRoyalFinish(ids, enabled: false, all: true) }
        }
        .fixedSize()
        .disabled(ids.isEmpty || model.selected == nil || model.busy)
    }

    private func load() async {
        draft.loading = true
        draft.error = nil
        do {
            let catalog = try await model.loadCardSearch()
            try Task.checkCancellation()
            draft.catalog = catalog
            refreshResults()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            draft.error = error.localizedDescription
        }
        draft.loading = false
    }

    private func refreshResults() {
        draft.results = draft.catalog?.results(for: draft.query) ?? .init()
    }
}

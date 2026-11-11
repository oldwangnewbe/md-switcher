import SwiftUI

final class CardSearchDraft: ObservableObject {
    @Published var query = ""
    @Published var matches = CardSearchCatalog.Results()
    @Published var onlyArtwork = false
    @Published var card: SearchCard?
    @Published var variantID: Int?
    @Published var submitted = false
    @Published var loading = true
    @Published var error: String?
    @Published var collectionMessage: String?
    @Published var creatingCollection = false
    @Published var collectionName = ""
    @Published var summons = Set<SummonAnimation>()
    @Published var reload = 0
    var catalog: CardSearchCatalog?
    var installed: [String: Int] = [:]
    var accountScope: (account: UInt64?, game: URL?) = (nil, nil)

    func choose(_ card: SearchCard?) {
        self.card = card
        variantID = card?.path.flatMap { installed[$0] }
        if card?.variants.contains(where: { $0.id == variantID }) != true { variantID = nil }
        submitted = false
        collectionMessage = nil
    }

    func refreshResults(resetVariant: Bool = false) {
        matches = catalog?.results(for: query, onlyArtwork: onlyArtwork) ?? CardSearchCatalog.Results()
        guard let current = matches.cards.first(where: { $0.id == card?.id }) else {
            choose(matches.cards.first)
            return
        }
        if resetVariant || (variantID != nil && !current.variants.contains { $0.id == variantID }) {
            choose(current)
        } else {
            card = current
        }
    }
}

struct CardSearchView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var draft: CardSearchDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("卡片搜索").font(.title2.bold())
            HStack {
                TextField("输入卡名、系列名或编号", text: $draft.query).textFieldStyle(.roundedBorder)
                Toggle("仅看可换异画", isOn: $draft.onlyArtwork)
            }
            .disabled(draft.loading || model.busy)
            if draft.loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取本机卡库…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = draft.error {
                VStack(spacing: 10) {
                    Text(error).foregroundStyle(.orange)
                    Button("重试") { draft.reload += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    results
                    Divider()
                    if let card = draft.card {
                        ScrollView { details(card) }
                    } else {
                        Text("选择一张卡，查看本机 MDPro3 的异画。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            if draft.submitted {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout)
                        .foregroundStyle(model.error ? Color.orange : .secondary)
                }
            }
            if let message = draft.collectionMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if let account = model.selected {
                    Text("所选账号：\(model.aliases[String(account.id)] ?? account.displayName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("加入合集") {
                    ForEach(model.artworkCollections) { collection in
                        Button(collection.name) { add(to: collection.id) }
                    }
                    Divider()
                    Button("新建合集并加入…") {
                        draft.collectionName = ""
                        draft.creatingCollection = true
                    }
                }
                .disabled(draft.card?.path == nil || draft.variantID == nil || model.busy)
                .help("选好一款异画后加入合集")
                Button("应用到所选账号") { apply(all: false) }
                    .disabled(draft.card?.path == nil || !model.canManageMods)
                    .buttonStyle(.borderedProminent)
                Button("应用到所有账号") { apply(all: true) }
                    .disabled(draft.card?.path == nil || !model.canApplyArtworkToAll)
            }
            .disabled(draft.loading || draft.error != nil)
        }
        .padding(22)
        .task(id: draft.reload) { await load() }
        .onChange(of: draft.query) { _ in draft.refreshResults() }
        .onChange(of: draft.onlyArtwork) { _ in draft.refreshResults() }
        .alert("新建异画合集", isPresented: $draft.creatingCollection) {
            TextField("合集名称", text: $draft.collectionName)
            Button("取消", role: .cancel) {}
            Button("新建并加入") {
                do { add(to: try model.createArtworkCollection(draft.collectionName)) }
                catch { draft.collectionMessage = error.localizedDescription }
            }
        }
    }

    private var results: some View {
        Group {
            if draft.matches.cards.isEmpty {
                Text(draft.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "输入卡名或系列名开始搜索" : "未找到匹配的卡片")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if !draft.matches.series.isEmpty {
                            resultHeader("系列卡 · \(draft.query)")
                            ForEach(draft.matches.series, content: resultRow)
                        }
                        if !draft.matches.names.isEmpty {
                            if !draft.matches.series.isEmpty { resultHeader("卡名匹配") }
                            ForEach(draft.matches.names, content: resultRow)
                        }
                    }
                }
                .disabled(model.busy)
            }
        }
        .frame(minWidth: 225, idealWidth: 290, maxWidth: 315)
    }

    private func resultHeader(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func resultRow(_ card: SearchCard) -> some View {
        Button { draft.choose(card) } label: {
            HStack(spacing: 8) {
                CardThumbnail(url: draft.catalog?.thumbnailURL(for: card))
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.name).font(.body.weight(.medium)).lineLimit(1)
                    if let name = card.proName, card.masterName != nil, name != card.masterName {
                        Text("MDPro3 · \(name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(draft.card?.id == card.id ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func details(_ card: SearchCard) -> some View {
        let installed = card.path.flatMap { draft.installed[$0] }
        let chosen = card.variants.first(where: { $0.id == draft.variantID })
        let image = draft.catalog?.artworkPreview(for: card, variant: chosen).flatMap { NSImage(contentsOf: $0) }
        return VStack(alignment: .leading, spacing: 9) {
            Text(card.name).font(.headline)
            if let master = card.masterName { Text("大师决斗 · \(master)").foregroundStyle(.secondary) }
            if let pro = card.proName { Text("MDPro3 · \(pro)").foregroundStyle(.secondary) }
            if let cid = card.cid { Text("大师决斗编号 \(cid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if card.masterName == nil || card.proName == nil {
                Text("两边的卡片编号尚未匹配。").foregroundStyle(.orange)
            } else if card.variants.isEmpty {
                Text("本机 MDPro3 未找到异画。").foregroundStyle(.secondary)
            } else if card.path == nil {
                Text("有异画，尚未匹配到可按账号替换的《大师决斗》卡图资源。")
                    .foregroundStyle(.orange)
            }
            if let image {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(width: 194, height: 194)
                    .accessibilityLabel(chosen == nil ? "原卡图预览" : "所选异画预览")
            } else {
                Text(chosen == nil ? "本机 MDPro3 未找到原卡图。" : "本机 MDPro3 未找到这款异画的预览。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !card.variants.isEmpty || installed != nil {
                Picker("卡图", selection: $draft.variantID) {
                    Text("原卡图").tag(nil as Int?)
                    ForEach(Array(card.variants.enumerated()), id: \.element.id) { index, variant in
                        Text("\(variant.overFrame == nil ? "异画" : "超框异画") \(index + 1)").tag(Optional(variant.id))
                    }
                }
                .disabled(model.busy)
                Text(chosen?.overFrame == nil ? "应用会替换这张卡在《大师决斗》里的卡图。" : "应用后会在《大师决斗》里显示完整超框卡面。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let chosen {
                summonOptions(for: card, artworkID: chosen.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func summonOptions(for card: SearchCard, artworkID: Int) -> some View {
        let hasSource = model.proDirectory.map { SummonAnimation.hasSource(artworkID: artworkID, proDirectory: $0) } ?? false
        if hasSource, let option = SummonAnimation.all.first(where: { $0.cid == card.cid && $0.artworkID == artworkID }) {
            let installed = draft.summons.contains(option)
            HStack(spacing: 8) {
                Text("MDPro3 有召唤动画").font(.caption).foregroundStyle(.secondary)
                Button(installed ? "恢复原演出" : "应用这款召唤动画") {
                    var next = draft.summons.filter { $0.cid != option.cid }
                    if !installed { next.insert(option) }
                    draft.submitted = true
                    model.updateSummonAnimation(next) { success in
                        if success, let choices = try? model.summonSelections() { draft.summons = choices }
                    }
                }
                .disabled(!model.canManageMods)
            }
        } else {
            Text(hasSource ? "当前仅支持替换已有的召唤演出" : "MDPro3 未找到这款异画的召唤动画")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        draft.loading = true
        draft.error = nil
        do {
            let catalog = try await model.loadCardSearch()
            try Task.checkCancellation()
            let installed = try model.artworkSelections()
            let summons = try model.summonSelections()
            let scope = (model.selectedID, model.installation?.game)
            let path = draft.card?.path
            let resetVariant = draft.accountScope != scope || path.flatMap { draft.installed[$0] } != path.flatMap { installed[$0] }
            draft.catalog = catalog
            draft.installed = installed
            draft.summons = summons
            draft.accountScope = scope
            draft.refreshResults(resetVariant: resetVariant)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            draft.error = error.localizedDescription
        }
        draft.loading = false
    }

    private func apply(all: Bool) {
        guard let card = draft.card else { return }
        let variant = card.variants.first { $0.id == draft.variantID }
        draft.submitted = true
        model.applySearchCard(card, variant: variant, all: all) {
            if let selection = try? model.artworkSelections() { draft.installed = selection }
        }
    }

    private func add(to id: String) {
        guard let card = draft.card, let cid = card.cid, let variant = draft.variantID,
              let collection = model.artworkCollections.first(where: { $0.id == id }) else { return }
        model.setArtworkCollectionChoice(id, cid: cid, variant: variant)
        draft.collectionMessage = "「\(card.name)」已加入「\(collection.name)」。"
    }
}

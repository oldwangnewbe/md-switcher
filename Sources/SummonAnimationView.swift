import SwiftUI

private final class SummonAnimationDraft: ObservableObject {
    @Published var selected = Set<SummonAnimation>()
    @Published var submitted = false
    @Published var readError: String?
    @Published var category = SummonAnimation.Category.replacement
    @Published var catalog: CardSearchCatalog?
    @Published var loading = true
    @Published var query = ""
    @Published var installedArt: [String: Int] = [:]
    @Published var reload = 0
}

struct SummonAnimationView: View {
    @ObservedObject var model: SwitcherModel
    @StateObject private var draft = SummonAnimationDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("卡片演出").font(.title2.bold())
            if let account = model.selected {
                Text("所选账号：\(model.aliases[String(account.id)] ?? account.displayName)")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(SummonAnimation.Category.allCases, id: \.self) { category in
                    categoryButton(category)
                }
            }
            Text(draft.category.description).font(.callout).foregroundStyle(.secondary)
            TextField("搜索卡名或画款编号", text: $draft.query).textFieldStyle(.roundedBorder)
            if draft.loading {
                ProgressView("正在核对本机演出素材…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if draft.catalog == nil {
                Button("重试") { draft.reload += 1 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let cards = filteredCards
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        performanceRows(cards)
                        if cards.isEmpty { Text("没有匹配的演出").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(draft.category)
                .frame(maxHeight: .infinity)
            }
            Text("退出游戏后应用，再到单人模式用普通版卡片测试。")
                .font(.callout).foregroundStyle(.secondary)
            if let readError = draft.readError {
                Text(readError).foregroundStyle(.orange)
            } else if draft.submitted {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).foregroundStyle(model.error ? Color.orange : .secondary)
                }
            }
            HStack {
                Button("恢复原演出") { apply([]) }
                    .disabled(!model.canManageMods)
                Spacer()
                Button("应用到所选账号") { apply(draft.selected) }.buttonStyle(.borderedProminent)
                    .disabled(!model.canManageMods || draft.loading || draft.readError != nil)
            }
        }
        .padding(22)
        .task(id: draft.reload) {
            draft.loading = true
            do {
                draft.catalog = try await model.loadCardSearch()
                loadSelections()
            } catch {
                if !Task.isCancelled { draft.readError = error.localizedDescription }
            }
            if !Task.isCancelled { draft.loading = false }
        }
        .onChange(of: model.selected?.id) { _ in
            draft.submitted = false
            loadSelections()
        }
    }

    private func categoryButton(_ category: SummonAnimation.Category) -> some View {
        let active = draft.category == category
        return Button { draft.category = category } label: {
            Text(category.rawValue).font(.callout.weight(.medium))
                .foregroundStyle(active ? Color.accentColor : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var filteredCards: [SummonAnimation] {
        let options = Set(draft.catalog?.performances ?? []).union(draft.selected)
        let query = draft.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? nil : Set(draft.catalog?.results(for: query).cards.compactMap(\.cid) ?? [])
        return options.filter {
            $0.category == draft.category && (matches == nil || matches?.contains($0.cid) == true ||
                $0.name.localizedCaseInsensitiveContains(query) || String($0.artworkID).hasPrefix(query))
        }.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if $0.cid != $1.cid { return $0.cid < $1.cid }
            return $0.artworkID < $1.artworkID
        }
    }

    private func performanceRows(_ cards: [SummonAnimation]) -> some View {
        ForEach(cards) { card in
            let searchCard = draft.catalog?.card(cid: card.cid)
            let installed = searchCard?.path.flatMap { draft.installedArt[$0] }
            let original = searchCard?.originalArtworkID == card.artworkID
            let variant = searchCard?.variants.firstIndex { $0.id == card.artworkID }
            let artworkLabel = original ? "原卡图" : variant.map { "异画 \($0 + 1)" } ?? "画款 \(card.artworkID)"
            let matchesArt = installed == nil || installed == card.artworkID
            Toggle(isOn: Binding(
                get: { draft.selected.contains(card) },
                set: { enabled in
                    draft.selected = draft.selected.filter { $0.slot != card.slot }
                    if enabled { draft.selected.insert(card) }
                }
            )) {
                HStack(spacing: 8) {
                    CardThumbnail(url: searchCard.flatMap { search in
                        if let variant { return draft.catalog?.preview(search.variants[variant]) }
                        return original ? draft.catalog?.artworkPreview(for: search, variant: nil) : nil
                    })
                    Text(card.name).lineLimit(1)
                    Text(artworkLabel).font(.caption).foregroundStyle(.secondary)
                    if !matchesArt { Text("与已安装卡图不符").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .disabled(model.busy || draft.readError != nil || (!matchesArt && !draft.selected.contains(card)))
            .padding(.vertical, 2)
        }
    }

    private func loadSelections() {
        do {
            draft.selected = try model.summonSelections(catalog: draft.catalog?.performances ?? [])
            draft.installedArt = try model.artworkSelections()
            // Migrate old selections to the installed artwork when editing this account.
            for card in draft.selected {
                guard let search = draft.catalog?.card(cid: card.cid),
                      let path = search.path, let artwork = draft.installedArt[path],
                      artwork != card.artworkID else { continue }
                draft.selected.remove(card)
                if let match = search.performances?.first(where: { $0.slot == card.slot && $0.artworkID == artwork }) {
                    draft.selected.insert(match)
                }
            }
            draft.readError = nil
        } catch {
            draft.readError = error.localizedDescription
        }
    }

    private func apply(_ selection: Set<SummonAnimation>) {
        draft.submitted = true
        model.updateSummonAnimation(selection) { success in
            if success { loadSelections() }
        }
    }
}

import SwiftUI

struct SwitcherWorkspace: View {
    private enum Page: CaseIterable {
        case accounts, search, collections, royalFinish, summons, skyStriker, settings

        var label: (title: String, icon: String) {
            switch self {
            case .accounts: ("账号切换", "person.2")
            case .search: ("卡片搜索", "magnifyingglass")
            case .collections: ("异画合集", "rectangle.on.rectangle")
            case .royalFinish: ("动态镜碎", "sparkles")
            case .summons: ("召唤动画", "play.rectangle")
            case .skyStriker: ("闪刀异画", "bolt")
            case .settings: ("设置", "gearshape")
            }
        }
    }

    @ObservedObject var model: SwitcherModel
    @StateObject private var navigation = Navigation()
    @StateObject private var search = CardSearchDraft()
    @StateObject private var collections = ArtworkCollectionsDraft()
    @StateObject private var royalFinish = RoyalFinishDraft()

    private final class Navigation: ObservableObject {
        @Published var page = Page.accounts
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Page.allCases.filter { page in
                page != .settings && (page != .skyStriker || SkyStrikerPack.availableDirectory != nil)
            }, id: \.self, content: sidebarItem)
            Spacer(minLength: 12)
            Divider().padding(.vertical, 5)
            sidebarItem(.settings)
        }
        .padding(12)
        .frame(width: 172)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .disabled(model.busy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("功能导航")
    }

    private func sidebarItem(_ page: Page) -> some View {
        let active = navigation.page == page
        return Button {
            navigation.page = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.label.icon)
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(page.label.title).fontWeight(active ? .semibold : .regular)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 35, alignment: .leading)
            .background(active ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch navigation.page {
        case .accounts:
            SwitcherView(model: model, openSettings: { navigation.page = .settings })
        case .search:
            CardSearchView(model: model, draft: search)
        case .collections:
            ArtworkCollectionsView(model: model, draft: collections, openSearch: { navigation.page = .search })
        case .royalFinish:
            RoyalFinishView(model: model, draft: royalFinish)
        case .summons:
            SummonAnimationView(model: model)
        case .skyStriker:
            SkyStrikerView(model: model)
        case .settings:
            SwitcherSettingsView(model: model)
        }
    }
}

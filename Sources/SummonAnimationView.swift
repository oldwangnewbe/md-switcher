import SwiftUI

private final class SummonAnimationDraft: ObservableObject {
    @Published var selected = Set<SummonAnimation>()
    @Published var submitted = false
    @Published var readError: String?
}

struct SummonAnimationView: View {
    @ObservedObject var model: SwitcherModel
    @StateObject private var draft = SummonAnimationDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("召唤动画").font(.title2.bold())
            if let account = model.selected {
                Text("所选账号：\(model.aliases[String(account.id)] ?? account.displayName)")
                    .foregroundStyle(.secondary)
            }
            Text("勾选后，普通版卡片会播放对应的异画召唤演出。卡图可在异画合集里单独选择。")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(SummonAnimation.all) { card in
                        let available = model.proDirectory.map {
                            SummonAnimation.hasSource(artworkID: card.artworkID, proDirectory: $0)
                        } ?? false
                        Toggle(isOn: Binding(
                            get: { draft.selected.contains(card) },
                            set: { enabled in
                                draft.selected = draft.selected.filter { $0.cid != card.cid }
                                if enabled { draft.selected.insert(card) }
                            }
                        )) {
                            let multiple = SummonAnimation.all.filter { $0.cid == card.cid }.count > 1
                            let label = multiple ? "\(card.name) · \(card.artworkID)" : card.name
                            Text(available ? label : "\(label)（MDPro3 素材未找到）")
                        }
                        .disabled(model.busy || draft.readError != nil || !available)
                    }
                }
            }
            Text("请退出大师决斗后应用，进入单人模式召唤普通版卡片查看。")
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
                    .disabled(!model.canManageMods || draft.readError != nil)
            }
        }
        .padding(22)
        .onAppear(perform: load)
    }

    private func load() {
        do {
            draft.selected = try model.summonSelections()
            draft.readError = nil
        } catch {
            draft.readError = error.localizedDescription
        }
    }

    private func apply(_ selection: Set<SummonAnimation>) {
        draft.submitted = true
        model.updateSummonAnimation(selection) { success in
            if success { load() }
        }
    }
}

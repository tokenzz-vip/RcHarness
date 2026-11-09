import SwiftUI

struct ProfilesPage: View {
    @ObservedObject var model: RemoteDashboardModel
    let onNewProfile: () -> Void
    let onDuplicate: (UUID) -> Void

    var body: some View {
        SettingsPanel {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group").foregroundStyle(Color.accentColor)
                    Text("\(model.remoteProfile.shortName) 的方案").font(.system(size: 15, weight: .semibold))
                }
                Spacer(minLength: 12)
                Button("管理绑定") { model.page = .harness }
                Button(action: onNewProfile) {
                    Label("新建方案", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            Text("仅显示当前遥控器的方案，全局按键也按遥控器分别保存。同一方案可绑定多个 Harness，修改后对所有绑定的 Harness 生效。\n默认方案、内置 Harness 同名方案及已绑定 Harness 的方案不可删除。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            ForEach(model.profiles) { profile in
                if profile.id != model.profiles.first?.id { Divider() }
                row(profile)
            }
        }
    }

    private func row(_ profile: SavedKeyProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 7) {
                Text(model.profileDisplayName(profile)).font(.system(size: 13, weight: .semibold))
                let harnesses = model.boundHarnesses(for: profile.id)
                Text(harnesses.isEmpty ? (profile.id == SavedKeyProfile.defaultID ? "未匹配 Harness 时使用" : "未绑定 Harness") : "已绑定：" + harnesses.map(\.name).joined(separator: "、"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.selectedProfileID == profile.id { SettingsStatus(title: "当前方案", color: .accentColor) }
            Button("编辑按键") { model.activateProfile(profile.id); model.page = .mapping }
            Button { onDuplicate(profile.id) } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("复制方案并重命名")
            if model.canDeleteProfile(profile.id) {
                Button { model.deleteProfile(profile.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除未绑定的方案")
            }
        }
    }
}

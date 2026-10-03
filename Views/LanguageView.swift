import SwiftUI

/// 语言设置页：默认「跟随系统」，也可指定某一种语言。
/// 选择写入 AppleLanguages 后立即弹重启确认；选了「稍后」则下次启动自然生效
struct LanguageView: View {
    @State private var followsSystem = AppLanguageSetting.followsSystem
    @State private var selectedCode = AppLanguageSetting.overrideCode
    @State private var showRestartAlert = false

    var body: some View {
        List {
            Button { choose(nil) } label: {
                row(L("System Default"), checked: followsSystem)
            }
            ForEach(AppLanguageSetting.sortedByLocalizedName) { lang in
                Button { choose(lang.code) } label: {
                    row(lang.nativeName, checked: !followsSystem && selectedCode == lang.code)
                }
            }
        }
        .navigationTitle(L("Language"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L("Restart Required"), isPresented: $showRestartAlert) {
            Button(L("Restart Now")) {
                // 先让弹窗收起的动画走完再退出，不然画面会闪一下
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
            Button(L("Later"), role: .cancel) {}
        } message: {
            Text(L("Sonux needs to restart to switch language."))
        }
        .accessibilityIdentifier("language-page")
    }

    private func row(_ name: String, checked: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            if checked {
                Image(systemName: "checkmark")
                    .foregroundStyle(.indigo)
            }
        }
        .contentShape(Rectangle())
    }

    /// 记下偏好；只有真正改变生效语言时才弹重启确认
    private func choose(_ code: String?) {
        AppLanguageSetting.select(code)
        followsSystem = code == nil
        selectedCode = code
        let newEffective = code ?? AppLanguageSetting.systemResolvedCode
        if newEffective != AppLanguageSetting.effectiveCode {
            showRestartAlert = true
        }
    }
}

import SwiftUI

@main
struct BooheeLiteApp: App {
    @StateObject var store = Store()
    @Environment(\.scenePhase) var phase
    @AppStorage("healthIntroShown") var healthIntroShown = false
    @State var showHealthIntro = false
    var body: some Scene {
        WindowGroup {
            // 从左到右：我的（账号 / 健康 App / 资料 / AI 识别 / 数据）· 目标（方案 / 辅助目标）· 记录（饮食 / 作息运动 / 身体）· 趋势；标题和 Tab 重复，各页不显示导航标题
            TabView(selection: $store.tab) {
                ProfileView().tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(0)
                GoalView().tabItem { Label("目标", systemImage: "flag.checkered") }.tag(1)
                RecordView().tabItem { Label("记录", systemImage: "list.bullet.clipboard") }.tag(2)
                TrendView().tabItem { Label("趋势", systemImage: "chart.line.uptrend.xyaxis") }.tag(3)
            }
            .tint(Theme.accent)
            .preferredColorScheme(.light)  // 色板只有浅色值，App 不随系统变深色（Info.plist 也锁了 UIUserInterfaceStyle）
            .environmentObject(store).environmentObject(store.health)
            // 第一次打开先说明读哪些健康数据、为什么，点「继续」才弹系统授权；之后每次启动直接刷新
            .task {
                if UserDefaults.standard.bool(forKey: "skipHealth") { return }
                if healthIntroShown { await store.health.authorize() } else { showHealthIntro = true }
            }
            .sheet(isPresented: $showHealthIntro) {
                HealthIntroSheet { allow in
                    healthIntroShown = true; showHealthIntro = false
                    if allow { Task { await store.health.authorize() } }
                }
            }
            .onChange(of: phase) { _, p in
                if p == .active { Task { if healthIntroShown { await store.health.refresh() } } } else { store.save(); Cloud.scheduleBackup() }
            }
        }
        .backgroundTask(.appRefresh(Cloud.backupTask)) { Cloud.scheduleBackup(); await store.syncNow() }
    }
}

// 截图用启动参数：xcrun simctl launch booted dev.mindbar.boohee -skipHealth YES -tab 0 我的|1 目标|2 记录|3 趋势 -sheet food|plan -pane 0|1|2
let LAUNCH_SHEET = UserDefaults.standard.string(forKey: "sheet")

// MARK: 设计规范 v2：品牌绿、墨色各分 10 / 7 / 3 / 1 四档；只有浅色

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

enum Theme {
    static let accent = Color(hex: 0x00A887)   // 品牌绿 · 10：环、进度、主按钮底、核心大数字、Tab 选中（白底 3.0:1，不做小字）
    static let brand7 = Color(hex: 0x4DC2AB)   // 图表次要数据
    static let brand3 = Color(hex: 0xB3E5DB)   // 次按钮底、已记圆底
    static let brand1 = Color(hex: 0xE6F6F3)   // 「自动」标签底
    static let ink = Color(hex: 0x1C2420)      // 墨色 · 10：标题、列表标签、数值、未完成图标
    static let ink7 = Color(hex: 0x606663)     // 次文字：模块标题、单位、右侧值、说明
    static let ink3 = Color(hex: 0xBBBDBC)     // 箭头、禁用、读数点
    static let page = Color(hex: 0xF2F2F7)     // 页面底：分隔线、轨道、图标默认圆底、分段控件底
    static let warn = Color(hex: 0xFF9500)     // 提醒：多吃了、计划线、超限数值
    static let danger = Color(hex: 0xFF3B30)   // 只给删除 / 结束
    static let water = Color(hex: 0x32ADE6), sleep = Color(hex: 0x5856D6)
    static let card = Color.white
}

extension Font {
    static let bigNum = Font.system(size: 44, weight: .bold, design: .rounded)     // 每屏一个核心数：还能吃、已减、拍照总热量、录入值
    static let num30 = Font.system(size: 30, weight: .bold, design: .rounded)      // 次级数字：目标体重
    static let sideNum = Font.system(size: 20, weight: .semibold, design: .rounded) // 环 / 半圆两侧
    static let cardTitle = Font.callout.weight(.semibold)                          // 卡内标题 16
}

// 卡片外的模块标题：17 · Semibold · 墨色 7，和卡片左边对齐
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline).foregroundStyle(Theme.ink7).textCase(nil).padding(.leading, -4) }
}

// 可点的行一律右侧箭头（墨色 3）
struct Chevron: View {
    var body: some View { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3) }
}

// 状态标签：自动 / 手动 / 已结束
struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        let (bg, fg): (Color, Color) = switch text {
        case "自动": (Theme.brand1, Theme.accent)
        case "手动": (Theme.warn.opacity(0.15), Theme.ink7)
        default: (Theme.page, Theme.ink7)
        }
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(fg).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(bg))
    }
}

// 按钮：高 44、胶囊、15 · Semibold；主 = 品牌绿底白字，次 = 浅绿底墨色字
struct PillButton: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).lineLimit(1)
            .foregroundStyle(primary ? Color.white : Theme.ink)
            .frame(minHeight: 44).padding(.horizontal, 16)
            .background(Capsule().fill(primary ? Theme.accent : Theme.brand3))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

// 分段控件：全 App 只用这一种（餐别、围度部位）。页面底胶囊，选中块白底轻投影 + 文字下品牌绿短线（规范 6.4）
struct Segmented<T: Hashable>: View {
    let items: [T], label: (T) -> String
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { i in
                let on = i == selection
                Button { withAnimation(.snappy) { selection = i } } label: {
                    Text(label(i)).font(.subheadline.weight(on ? .semibold : .regular)).foregroundStyle(on ? Theme.ink : Theme.ink7).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .overlay(alignment: .bottom) { if on { Capsule().fill(Theme.accent).frame(width: 16, height: 3).padding(.bottom, 3) } }
                        .background { if on { Capsule().fill(Color.white).shadow(color: .black.opacity(0.08), radius: 2, y: 1) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(2).background(Capsule().fill(Theme.page))
    }
}

// 卡片：白底、圆角 22、左右内边距 16；列表行自带 44 行高，所以纯列表卡上下只留 4
struct Card<C: View>: View {
    var v: CGFloat = 16
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16).padding(.vertical, v).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
    }
}

// 卡内列表行：标签 15 墨色，右侧值 13 墨色 7；可点的带箭头；行高 44
// 系统 Form 里（我的、调整方案）跟同页的 Picker / 按钮一样用 17，行高交给 Form（44），不再自己垫 44 把行撑高
struct InFormKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var inForm: Bool { get { self[InFormKey.self] } set { self[InFormKey.self] = newValue } } }

struct CardRow: View {
    let title: String
    var icon: String? = nil, tint = Theme.ink, value: String? = nil, tag: String? = nil, sub: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.inForm) var inForm
    var body: some View {
        let row = HStack(spacing: 10) {
            if let icon { Image(systemName: icon).foregroundStyle(tint).frame(width: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(inForm ? .body : .subheadline).foregroundStyle(Theme.ink)
                if let sub { Text(sub).font(.caption2).foregroundStyle(Theme.ink7) }
            }
            Spacer(minLength: 8)
            if let tag { Tag(tag) }
            if let value { Text(value).font(inForm ? .body : .footnote).foregroundStyle(Theme.ink7).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8) }
            if action != nil { Chevron() }
        }.frame(minHeight: inForm ? nil : 44).contentShape(Rectangle())
        if let action { Button(action: action) { row }.buttonStyle(.plain) } else { row }
    }
}

// 卡片里的行左滑删除（卡片不是 List，用不了系统 swipeActions）：左滑露出红色「删除」，滑过一大半直接删；打开时点行先收起
struct SwipeToDelete: ViewModifier {
    let delete: () -> Void
    @State var x: CGFloat = 0
    @State var from: CGFloat = 0
    let w: CGFloat = 80
    func body(content: Content) -> some View {
        content
            .disabled(x != 0)  // 拖动时手指松开不再算点行（否则左滑会顺带打开编辑）
            .background(Theme.card)
            .overlay { if x != 0 { Color.white.opacity(0.001).onTapGesture { close() } } }
            .offset(x: x)
            .background(alignment: .trailing) {
                Button { remove() } label: {
                    Text("删除").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                        .frame(width: max(-x, 0)).frame(maxHeight: .infinity).background(Theme.danger)
                }.buttonStyle(.plain).accessibilityHidden(x == 0)
            }
            .clipped()
            .simultaneousGesture(DragGesture(minimumDistance: 20)
                .onChanged { g in if abs(g.translation.width) > abs(g.translation.height) { x = min(0, from + g.translation.width) } }
                .onEnded { _ in if x < -2.5 * w { remove() } else if x < -w / 2 { withAnimation(.snappy) { x = -w }; from = -w } else { close() } })
            .accessibilityAction(named: "删除") { remove() }
    }
    func close() { withAnimation(.snappy) { x = 0 }; from = 0 }
    func remove() { x = 0; from = 0; withAnimation(.snappy) { delete() } }
}

extension View { func swipeToDelete(_ delete: @escaping () -> Void) -> some View { modifier(SwipeToDelete(delete: delete)) } }

// 分隔线：页面底色 1pt
struct Sep: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(Theme.page).frame(height: 1).padding(.leading, inset) }
}

// 数字写法：千分位（1,500）；带正负号的用真正的减号 −
func fmt0(_ x: Double) -> String { Int(x.rounded()).formatted() }
func signed(_ x: Double, _ f: String = "%.1f") -> String { (x < 0 ? "−" : "+") + String(format: f, abs(x)) }

extension View {
    // 各页不显示导航标题后，内容滚到状态栏下面会和时间叠在一起：给状态栏垫一层系统材质（同导航栏滚动时的效果）
    // 列表 / ScrollView 本身铺满全屏，用 GeometryReader 读出状态栏高度再画，不拦截点击
    func statusBarCover() -> some View {
        overlay(alignment: .top) {
            GeometryReader { g in Rectangle().fill(.bar).frame(height: g.safeAreaInsets.top).ignoresSafeArea(edges: .top) }.allowsHitTesting(false)
        }
    }
    // 分隔线用页面底色
    func pageSeparator() -> some View { listRowSeparatorTint(Theme.page) }
}

func openSettings() { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }

func mealNow() -> String {
    let h = Calendar.current.component(.hour, from: .now)
    return h < 10 ? "早餐" : h < 15 ? "午餐" : h < 21 ? "晚餐" : "加餐"
}

// 授权前说明：读什么、为什么；「继续」才弹系统授权，「稍后」可以到「我的 → 健康 App」再连
struct HealthIntroSheet: View {
    let done: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "heart.text.square.fill").font(.system(size: 44)).foregroundStyle(Theme.accent).padding(.top, 28)
            Text("连接健康 App").font(.title2.bold()).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 12) {
                item("flame.fill", "读活动能量、静息能量、步数", "算每天的热量消耗和还能吃多少")
                item("figure.run", "读体能训练、睡眠", "手表记的运动和睡眠自动同步，不用手记")
                item("scalemass.fill", "读写体重、饮食热量、喝水", "在这里记的会写回健康 App")
            }
            Text("不连接也能用：消耗按基础代谢估算。以后可以在「我的 → 健康 App」里连接。").font(.footnote).foregroundStyle(Theme.ink7)
            Spacer()
            Button { done(true) } label: { Text("继续").frame(maxWidth: .infinity) }.buttonStyle(PillButton())
            Button { done(false) } label: { Text("稍后").font(.subheadline).foregroundStyle(Theme.ink7).frame(maxWidth: .infinity, minHeight: 44) }
        }
        .padding(.horizontal, 24).padding(.bottom, 8)
        .interactiveDismissDisabled()
        .presentationDetents([.large])
    }

    func item(_ icon: String, _ t: String, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink); Text(s).font(.footnote).foregroundStyle(Theme.ink7) }
        }
    }
}

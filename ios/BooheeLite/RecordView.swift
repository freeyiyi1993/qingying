import SwiftUI
import PhotosUI
import AVFoundation

// MARK: 记录（今日即记录）：热量卡 + 三个子页（饮食 / 作息运动 / 身体），当天明细都在子页卡片里
// 版式按设计稿 v2（UI 优化对比 01 / 02 / 02d / 05 / 06）

let MEAL_QUICK: [(name: String, icon: String)] = [("早餐", "sunrise.fill"), ("午餐", "fork.knife"), ("晚餐", "moon.stars.fill"), ("加餐", "carrot.fill")]
let REST_QUICK: [(name: String, icon: String)] = [("睡眠", "bed.double.fill"), ("喝水", "drop.fill"), ("步数", "shoeprints.fill"), ("运动", "figure.run")]
// 身体维度：体重 + 七个围度 + 体脂；每一项固定一种量法（点开那一行时显示）
let BODY_DIMS: [(name: String, unit: String, key: WritableKeyPath<BodyEntry, Double?>, how: String)] =
    [("体重", "kg", \.weight, WEIGH_RULE)] + GIRTHS.map { ($0.name, "cm", $0.key, $0.how) } + [("体脂率", "%", \.bodyfat, "用同一台体脂秤，在同一个时间段测")]

// 作息和运动合并成一个子页（两页原来内容都很少）
enum Pane: Int, CaseIterable, Identifiable { case food, rest, body; var id: Int { rawValue }; var name: String { ["饮食", "作息运动", "身体"][rawValue] } }
struct MealPick: Identifiable { let meal: String; var id: String { meal } }
struct PhotoJob: Identifiable { let id = UUID(); let image: UIImage }
struct DimPick: Identifiable { let index: Int; var id: Int { index } }
enum RestSheet: String, Identifiable { case sleep, water, steps; var id: String { rawValue } }

struct RecordView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var health: HealthService
    @State var day = Date.now
    @State var pane = Pane(rawValue: Int(UserDefaults.standard.string(forKey: "pane") ?? "") ?? 0) ?? .food  // 截图用：-pane 0|1|2
    @State var addMeal: MealPick?
    @State var dim: DimPick?
    @State var rest: RestSheet?
    @State var workout: ManualWorkout?  // 编辑手动运动
    @State var showWorkout = false
    @State var editLog: FoodLog?
    @State var showCalendar = false
    @State var showDetail = false  // 预算详情默认折叠
    @State var showCamera = false
    @State var showLibrary = false
    @State var cameraDenied = false
    @State var aiMissing = false
    @State var captured: UIImage?
    @State var pick: PhotosPickerItem?
    @State var photo: PhotoJob?
    @State var manualMeal: String?  // 识别失败点「手动记录」：拍照页关掉后再打开记餐

    var body: some View {
        let key = dayKey(day), s = store.summary(key)
        let logs = store.data.logs.filter { $0.date == key }
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if store.fresh && !store.cloud.signedIn && store.cloud.googleReady {  // 卸载重装后本机是空的：提示登录恢复
                        Card(v: 4) { CardRow(title: "以前用过？登录恢复记录", icon: "icloud.and.arrow.down", tint: Theme.accent) { store.tab = 0 } }
                    }
                    Card { heatCard(key, s, logs) }
                    Card(v: 4) {
                        PaneTabs(pane: $pane)
                        switch pane {
                        case .food: foodPane(key, logs)
                        case .rest: restPane(key, s)
                        case .body: bodyPane(key)
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            .background(Theme.page)
            .toolbar(.hidden, for: .navigationBar).statusBarCover()
            .refreshable { await health.refresh() }
            .sheet(item: $addMeal) { AddFoodView(day: key, meal: $0.meal) }
            .sheet(item: $dim) { DimInputSheet(day: key, dim: BODY_DIMS[$0.index]) }
            .sheet(isPresented: $showWorkout) { AddWorkoutView(day: key) }
            .sheet(item: $workout) { AddWorkoutView(day: key, editing: $0) }
            .sheet(item: $editLog) { LogEditSheet(log: $0) }
            .sheet(item: $rest) { r in
                switch r {
                case .sleep: SleepSheet(day: key)
                case .water: WaterSheet(day: key)
                case .steps: StepsSheet(day: key)
                }
            }
            .sheet(item: $photo, onDismiss: { if let m = manualMeal { manualMeal = nil; addMeal = MealPick(meal: m) } }) {
                PhotoEstimateView(image: $0.image, day: key) { manualMeal = $0 }
            }
            .sheet(isPresented: $showCalendar) { calendarSheet }
            .fullScreenCover(isPresented: $showCamera, onDismiss: { if let c = captured { captured = nil; photo = PhotoJob(image: c) } }) {
                CameraPicker(image: $captured).ignoresSafeArea()
            }
            .photosPicker(isPresented: $showLibrary, selection: $pick, matching: .images)
            .alert("需要相机权限", isPresented: $cameraDenied) {
                Button("去设置") { openSettings() }
                Button("改用相册") { showLibrary = true }
                Button("取消", role: .cancel) {}
            } message: { Text("在系统设置里允许「轻盈」使用相机，或者从相册选一张照片") }
            .alert("还没配置 AI 识别", isPresented: $aiMissing) {
                Button("去设置") { store.tab = 0 }
                Button("取消", role: .cancel) {}
            } message: { Text("到「我的 → AI 识别」选一个服务并填 API Key，就能拍照算热量") }
            .onChange(of: pick) { _, p in
                guard let p else { return }
                Task { if let d = try? await p.loadTransferable(type: Data.self), let i = UIImage(data: d) { photo = PhotoJob(image: i) }; pick = nil }
            }
            .onAppear {  // 截图用：-sheet food 打开「记午餐」；-photo <图片路径>（模拟器）直接进拍照估算
                if LAUNCH_SHEET == "food" { addMeal = MealPick(meal: "午餐") }
                if let p = UserDefaults.standard.string(forKey: "photo"), let i = UIImage(contentsOfFile: p) { photo = PhotoJob(image: i) }
            }
        }
    }

    // MARK: 热量卡：日期一行（点日期选日期）+ 热量环 + 预算详情（默认折叠）

    @ViewBuilder func heatCard(_ key: String, _ s: Store.Summary, _ logs: [FoodLog]) -> some View {
        let today = key == dayKey(), noWeight = store.weights().isEmpty
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button { showCalendar = true } label: {
                    HStack(spacing: 6) { Text(dayTitle(key)).fontWeight(.semibold); Text(monthDay(day)) }.font(.headline).foregroundStyle(Theme.ink)
                }.buttonStyle(.plain)
                if !today {
                    Button("回今天") { day = .now }.font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Theme.brand1)).buttonStyle(.plain)
                }
            }
            CalorieRing(s: s, noWeight: noWeight) { pane = .body; dim = DimPick(index: 0) }
            if !noWeight {
                HStack(spacing: 6) {
                    if s.raw < s.floor { Text("预算已按摄入下限 \(fmt0(s.floor)) 计算").foregroundStyle(Theme.warn); Text("·").foregroundStyle(Theme.ink3) }
                    Button { withAnimation(.snappy) { showDetail.toggle() } } label: {
                        HStack(spacing: 2) { Text("预算详情"); Image(systemName: showDetail ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold)) }
                    }.foregroundStyle(Theme.accent).buttonStyle(.plain)
                }.font(.caption)
                if showDetail {
                    VStack(spacing: 4) {
                        Text("预算 = 基础代谢 \(fmt0(s.bmr)) + 活动 \(fmt0(s.active)) × \(Int(s.eatBack * 100))% − 缺口 \(fmt0(s.goal)) = \(fmt0(s.raw))")
                        if store.data.plan == nil { Text("还没有进行中的减重方案，不扣缺口") }
                        if s.raw < s.floor { Text("低于摄入下限 \(fmt0(s.floor))（女 1,200 / 男 1,500），按下限算") }
                        Text(s.device ? "活动消耗来自健康 App（已含运动，不叠加）" : "没有手表数据：活动按 0.2 × 基础代谢 + 手动运动估算")
                        if logs.isEmpty, let e = store.estimate(key) { Text("这天日记估算缺口约 \(fmt0(e)) kcal") }
                        ForEach(s.alerts, id: \.self) { Text($0).foregroundStyle(Theme.warn) }
                    }.font(.caption2).foregroundStyle(Theme.ink7).monospacedDigit().multilineTextAlignment(.center)
                }
            }
        }.frame(maxWidth: .infinity)
    }

    // MARK: 饮食：四个餐次 + 拍照；下面是当天各餐，按热量从高到低，点一行改克数或删除

    @ViewBuilder func foodPane(_ key: String, _ logs: [FoodLog]) -> some View {
        QuickRow(items: MEAL_QUICK, done: Set(logs.map(\.meal))) { addMeal = MealPick(meal: $0) }
        HStack(spacing: 12) {
            Button { startCamera() } label: { Label("拍照算热量", systemImage: "camera.fill").frame(maxWidth: .infinity) }.buttonStyle(PillButton())
            Button { showLibrary = true } label: { Image(systemName: "photo.on.rectangle.angled").frame(width: 40) }
                .buttonStyle(PillButton(primary: false)).accessibilityLabel("从相册选")
        }.padding(.bottom, 12)
        if logs.isEmpty {
            Sep()
            Text("还没有饮食记录。点上面的餐次记一笔，或者拍照算热量").font(.footnote).foregroundStyle(Theme.ink7).padding(.vertical, 14)
        }
        ForEach(MEALS, id: \.self) { meal in
            let ls = logs.filter { $0.meal == meal }.sorted { $0.kcal > $1.kcal }
            if !ls.isEmpty {
                Sep()
                groupHeader("\(meal) · \(fmt0(ls.reduce(0) { $0 + $1.kcal })) kcal", "加\(meal)") { addMeal = MealPick(meal: meal) }
                ForEach(ls) { l in
                    Sep()
                    CardRow(title: l.name, value: "\(l.grams > 0 ? "\(fmt0(l.grams))g · " : "")\(fmt0(l.kcal)) kcal") { editLog = l }
                }
            }
        }
    }

    // MARK: 作息运动：四个快捷入口 + 记录运动 / 同步；作息（睡眠、喝水、步数，自动同步可改）；运动（手表自动 + 手动）

    @ViewBuilder func restPane(_ key: String, _ s: Store.Summary) -> some View {
        let auto = health.workouts.filter { $0.date == key }, manual = store.data.workouts.filter { $0.date == key }
        let sleep = store.sleep(key), water = store.water(key), steps = store.steps(key)
        let sleepManual = store.data.sleeps?.contains { $0.date == key } ?? false, stepsManual = store.data.steps?.contains { $0.date == key } ?? false
        let done: Set<String> = Set([sleep != nil ? "睡眠" : nil, water > 0 ? "喝水" : nil, steps != nil ? "步数" : nil, auto.isEmpty && manual.isEmpty ? nil : "运动"].compactMap { $0 })
        QuickRow(items: REST_QUICK, done: done) { n in
            switch n { case "睡眠": rest = .sleep; case "喝水": rest = .water; case "步数": rest = .steps; default: showWorkout = true }
        }
        HStack(spacing: 12) {
            Button { showWorkout = true } label: { Label("记录运动", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(PillButton())
            Button { Task { await health.refresh() } } label: {
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 40).symbolEffect(.pulse, isActive: health.syncing)
            }.buttonStyle(PillButton(primary: false)).disabled(health.syncing || !health.available).accessibilityLabel("从健康 App 同步")
        }.padding(.bottom, 12)
        Sep()
        HStack { Text("作息").font(.cardTitle).foregroundStyle(Theme.ink); Spacer(); Text("健康 App 自动同步").font(.footnote).foregroundStyle(Theme.ink7) }.frame(minHeight: 44)
        if health.noData { Sep(); CardRow(title: "没有读到健康数据", icon: "exclamationmark.circle.fill", tint: Theme.warn, value: "去设置", action: openSettings) }
        Sep()
        CardRow(title: "睡眠", value: sleep.map { String(format: "%.1f 小时", $0) } ?? "去记录", tag: sleep == nil ? nil : sleepManual ? "手动" : "自动") { rest = .sleep }
        Sep()
        CardRow(title: "喝水", value: water > 0 ? "\(fmt0(water)) ml" : "去记录") { rest = .water }
        Sep()
        CardRow(title: "步数", value: steps.map { "\(fmt0($0)) 步" } ?? "去记录", tag: steps == nil ? nil : stepsManual ? "手动" : "自动") { rest = .steps }
        Sep()
        groupHeader("运动 · \(fmt0(s.exercise)) kcal", "手动加运动") { showWorkout = true }
        if auto.isEmpty && manual.isEmpty {
            Text("今天还没有运动。手表记录的体能训练会自动同步，也可以点 + 手动加").font(.footnote).foregroundStyle(Theme.ink7).padding(.bottom, 12)
        }
        ForEach(auto) { w in Sep(); CardRow(title: w.type, value: "\(Int(w.minutes)) 分钟 · \(fmt0(w.kcal)) kcal", tag: "自动") }  // 健康 App 的只读
        ForEach(manual) { w in Sep(); CardRow(title: w.type, value: "\(Int(w.minutes)) 分钟 · \(fmt0(w.kcal)) kcal", tag: "手动") { workout = w } }
        if s.device && !manual.isEmpty { Text("当天已有手表数据，手动记录不重复计算").font(.caption2).foregroundStyle(Theme.ink7).padding(.bottom, 10) }
    }

    // MARK: 身体：每个维度一行，点哪一行就弹出那一项的输入

    @ViewBuilder func bodyPane(_ key: String) -> some View {
        let b = store.data.body.first { $0.date == key }
        ForEach(BODY_DIMS.indices, id: \.self) { i in
            let d = BODY_DIMS[i], v = b?[keyPath: d.key] ?? (i == 0 ? health.weights[key] : nil)
            if i > 0 { Sep() }
            CardRow(title: d.name, value: v.map { "\(fmt1($0)) \(d.unit)" } ?? "去记录") { dim = DimPick(index: i) }
        }
    }

    // 组标题（早餐 · 315 kcal / 运动 · 0 kcal）+ 右侧加号，命中区 44
    func groupHeader(_ t: String, _ a11y: String, _ add: @escaping () -> Void) -> some View {
        HStack {
            Text(t).font(.cardTitle).foregroundStyle(Theme.ink).monospacedDigit()
            Spacer()
            Button(action: add) { Image(systemName: "plus.circle").font(.title3).foregroundStyle(Theme.accent).frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(a11y).padding(.trailing, -10)
        }
    }

    // 拍照前先查：AI 没配好直接去设置；相机被拒绝时不打开黑屏相机，给「去设置 / 改用相册」
    func startCamera() {
        let c = AIConfig(store.data.profile)
        if c.provider != .mac && c.key.isEmpty { aiMissing = true; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: cameraDenied = true
        default: showCamera = true  // 没决定过的由系统弹授权
        }
    }

    var calendarSheet: some View {
        NavigationStack {
            DatePicker("日期", selection: $day, in: ...Date.now, displayedComponents: .date).datePickerStyle(.graphical).padding(.horizontal)
                .navigationTitle("选日期").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("回今天") { day = .now; showCalendar = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showCalendar = false } }
                }
        }.presentationDetents([.medium])
    }
}

let ZH = Locale(identifier: "zh_CN")
func monthDay(_ d: Date) -> String { let f = DateFormatter(); f.locale = ZH; f.dateFormat = "M月d日"; return f.string(from: d) }
func weekday(_ d: Date) -> String { let f = DateFormatter(); f.locale = ZH; f.dateFormat = "EEEE"; return f.string(from: d) }
func relDay(_ s: String) -> String {
    let d = ISO.date(s)!, n = Calendar.current.dateComponents([.day], from: d, to: Calendar.current.startOfDay(for: .now)).day ?? 0
    return n == 0 ? "今天" : n == 1 ? "昨天" : n == 2 ? "前天" : "\(monthDay(d)) \(weekday(d))"
}
// 日期行前半：今天 / 昨天 / 前天 / 星期几（后面跟 M月d日）
func dayTitle(_ s: String) -> String { let r = relDay(s); return r.count <= 2 ? r : weekday(ISO.date(s)!) }

// 预算 = 当天基础代谢 + 活动消耗 × 运动吃回比例 − 每日缺口（不低于摄入下限：女 1200 / 男 1500），见 Store.summary
// 环直径 150、线宽 12；中间 44 号核心数字，两侧 20 号
struct CalorieRing: View {
    let s: Store.Summary, noWeight: Bool, setWeight: () -> Void
    var body: some View {
        let over = s.remaining < 0, p = s.budget > 0 ? min(s.intake / s.budget, 1) : 0
        HStack(spacing: 0) {
            side("饮食摄入", s.intake)
            ZStack {
                Circle().stroke(Theme.page, lineWidth: 12)
                Circle().trim(from: 0, to: noWeight ? 0 : p).stroke(over ? Theme.warn : Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                if noWeight {  // 没有体重算不出基础代谢，不显示假预算
                    Button(action: setWeight) {
                        VStack(spacing: 4) { Image(systemName: "scalemass.fill").font(.title2); Text("先记体重").font(.subheadline.weight(.semibold)) }.foregroundStyle(Theme.accent)
                    }.buttonStyle(.plain)
                } else {
                    VStack(spacing: 0) {
                        Text(over ? "多吃了 · kcal" : "还能吃 · kcal").font(.caption2).foregroundStyle(Theme.ink7)
                        Text(fmt0(Double(r10(abs(s.remaining))))).font(.bigNum).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(over ? Theme.warn : Theme.accent).contentTransition(.numericText())
                        Text("预算 \(fmt0(s.budget))").font(.caption2).foregroundStyle(Theme.ink7).monospacedDigit()
                    }.padding(.horizontal, 14)
                }
            }.frame(width: 150, height: 150)
            side("活动消耗", s.active)
        }
        .animation(.snappy, value: s.intake)
    }

    func side(_ t: String, _ v: Double) -> some View {
        VStack(spacing: 2) {
            Text(fmt0(v)).font(.sideNum).foregroundStyle(Theme.ink).monospacedDigit().contentTransition(.numericText())
            Text(t).font(.caption2).foregroundStyle(Theme.ink7)
        }.frame(maxWidth: .infinity)
    }
}

// 子页标签：选中的墨色半粗 + 下面一条绿色短线，和下面的内容在同一张卡片里
struct PaneTabs: View {
    @Binding var pane: Pane
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Pane.allCases) { p in
                Button { withAnimation(.snappy) { pane = p } } label: {
                    VStack(spacing: 6) {
                        Text(p.name).font(.subheadline.weight(pane == p ? .semibold : .regular)).foregroundStyle(pane == p ? Theme.ink : Theme.ink7)
                        ZStack {
                            Capsule().fill(Color.clear).frame(width: 22, height: 3)
                            if pane == p { Capsule().fill(Theme.accent).frame(width: 22, height: 3).matchedGeometryEffect(id: "bar", in: ns) }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }
}

// 快捷入口：44 圆；没记的页面底 + 墨色图标，记过的浅绿底 + 绿色图标 + 勾
struct QuickRow: View {
    let items: [(name: String, icon: String)]
    let done: Set<String>
    let tap: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.name) { q in
                let on = done.contains(q.name)
                Button { tap(q.name) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: q.icon).font(.body).frame(width: 44, height: 44)
                            .background(Circle().fill(on ? Theme.brand3 : Theme.page))
                            .foregroundStyle(on ? Theme.accent : Theme.ink)
                            .overlay(alignment: .topTrailing) {
                                if on { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.accent).background(Circle().fill(Color.white)).offset(x: 2, y: -2) }
                            }
                        Text(q.name).font(.caption2).foregroundStyle(on ? Theme.accent : Theme.ink7)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 12)
    }
}

// 睡眠：自动从健康 App 取（标「自动」），改过的标「手动」并以手动为准；直接填小时数，± 每次 0.5
struct SleepSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var health: HealthService
    @Environment(\.dismiss) var dismiss
    let day: String
    @State var hours = 7.5
    @State var ready = false

    var body: some View {
        let mine = store.data.sleeps?.contains { $0.date == day } ?? false, auto = health.sleep[day]
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 24) {
                    stepButton("minus") { hours = max(hours - 0.5, 0.5) }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", hours)).font(.bigNum).foregroundStyle(Theme.accent).monospacedDigit().contentTransition(.numericText(value: hours))
                        Text("小时").font(.subheadline).foregroundStyle(Theme.ink7)
                    }.frame(minWidth: 140)
                    stepButton("plus") { hours = min(hours + 0.5, 16) }
                }
                if mine, let auto {
                    Button("恢复自动（健康 App \(String(format: "%.1f", auto)) 小时）") { store.setSleep(day, hours: nil); dismiss() }.font(.footnote).foregroundStyle(Theme.accent)
                } else if mine {
                    Button("删除这一项", role: .destructive) { store.setSleep(day, hours: nil); dismiss() }.font(.footnote)
                } else {
                    Text(auto == nil ? "按醒来那天记" : "现在是健康 App 同步的值，改了以后以你填的为准").font(.footnote).foregroundStyle(Theme.ink7)
                }
            }
            .padding()
            .navigationTitle("睡眠 · \(relDay(day))").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { store.setSleep(day, hours: hours); dismiss() } }
            }
            .onAppear { if !ready { hours = ((store.sleep(day) ?? store.data.profile.sleepGoal ?? 7.5) * 2).rounded() / 2; ready = true } }
        }.presentationDetents([.height(260)])
    }
}

func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).frame(width: 52, height: 44).background(Capsule().fill(Theme.page)) }
        .buttonStyle(.plain)
}

// 喝水：一点就记一杯，写回健康 App；撤销只撤本 App 记的（连健康 App 里那一条一起删）
struct WaterSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let day: String
    var body: some View {
        let ml = store.water(day), goal = store.data.profile.waterGoal ?? 2000
        let mine = (store.data.waters ?? []).filter { $0.date == day }
        NavigationStack {
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(fmt0(ml)).font(.bigNum).foregroundStyle(Theme.accent).monospacedDigit().contentTransition(.numericText(value: ml))
                    Text("/ \(fmt0(goal)) ml").font(.subheadline).foregroundStyle(Theme.ink7)
                }
                ProgressBar(value: ml / max(goal, 1), tint: Theme.water)
                HStack(spacing: 10) {
                    ForEach([150.0, 250.0, 500.0], id: \.self) { v in
                        Button("+\(Int(v))") { store.addWater(v, date: day) }.buttonStyle(PillButton(primary: false)).frame(maxWidth: .infinity)
                    }
                }
                Button { if let last = mine.last { store.removeWater(last.id) } } label: { Label("撤销上一杯", systemImage: "arrow.uturn.backward") }
                    .font(.footnote).foregroundStyle(mine.isEmpty ? Theme.ink3 : Theme.accent).disabled(mine.isEmpty)
            }
            .padding()
            .animation(.snappy, value: ml)
            .navigationTitle("喝水 · \(relDay(day))").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.height(300)])
    }
}

// 步数：健康 App 自动同步（标「自动」）；没有手表 / 手机没带时可以手动填，「恢复自动」回到同步值
struct StepsSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var health: HealthService
    @Environment(\.dismiss) var dismiss
    let day: String
    @State var text = ""
    @FocusState var focused: Bool
    var body: some View {
        let mine = store.data.steps?.contains { $0.date == day } ?? false, auto = health.steps[day]
        NavigationStack {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField(auto.map(fmt0) ?? "0", text: $text).keyboardType(.numberPad).multilineTextAlignment(.center).focused($focused)
                        .font(.bigNum).foregroundStyle(Theme.accent).frame(maxWidth: 200)
                    Text("步").font(.title3).foregroundStyle(Theme.ink7)
                }
                if mine {
                    Button(auto == nil ? "删除这一项" : "恢复自动（健康 App \(fmt0(auto!)) 步）", role: auto == nil ? .destructive : nil) { store.setSteps(day, nil); dismiss() }.font(.footnote)
                } else {
                    Text(auto == nil ? "健康 App 里没有这天的步数，可以手动填" : "现在是健康 App 同步的值，改了以后以你填的为准").font(.footnote).foregroundStyle(Theme.ink7)
                }
            }
            .padding()
            .navigationTitle("步数 · \(relDay(day))").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { store.setSteps(day, Double(text)); dismiss() }.disabled(Double(text) == nil) }
            }
            .onAppear { if mine, let v = store.steps(day) { text = "\(Int(v))" }; focused = true }
        }.presentationDetents([.height(260)])
    }
}

// 进度条：页面底轨道 + 分类色
struct ProgressBar: View {
    let value: Double, tint: Color
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Theme.page).overlay(alignment: .leading) { Capsule().fill(tint).frame(width: g.size.width * min(max(value, 0), 1)) }
        }.frame(height: 4)
    }
}

// 身体维度输入：点哪一行弹哪一项；体重用刻度尺，其余直接输入；量法写在这里，保证口径一致；当天已有记录带入已有值，按钮写「更新」
struct DimInputSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let day: String, dim: (name: String, unit: String, key: WritableKeyPath<BodyEntry, Double?>, how: String)
    @State var value = 60.0
    @State var text = ""
    @State var ready = false
    @State var last: Double?  // 当天没记时，最近一次的值只做占位提示，直接输入就是新值
    @FocusState var focused: Bool

    var body: some View {
        let isWeight = dim.key == \BodyEntry.weight, has = store.data.body.first { $0.date == day }?[keyPath: dim.key] != nil
        NavigationStack {
            VStack(spacing: 14) {
                if isWeight {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", value)).font(.bigNum).monospacedDigit().contentTransition(.numericText(value: value))
                        Text("kg").font(.title3).foregroundStyle(Theme.ink7)
                    }.foregroundStyle(Theme.accent)
                    if ready { RulerPicker(value: $value, range: 25...200, step: 0.1) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TextField(last.map(fmt1) ?? "—", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.center).focused($focused)
                            .font(.bigNum).foregroundStyle(Theme.accent).frame(maxWidth: 180)
                        Text(dim.unit).font(.title3).foregroundStyle(Theme.ink7)
                    }
                }
                Text(dim.how).font(.footnote).foregroundStyle(Theme.ink7).multilineTextAlignment(.center)
                if has { Button("删除这一项", role: .destructive) { store.setBody(day, dim.key, nil); dismiss() }.font(.footnote) }
            }
            .padding()
            .navigationTitle("\(dim.name) · \(relDay(day))").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(has ? "更新" : "保存") {
                        store.setBody(day, dim.key, isWeight ? (value * 10).rounded() / 10 : Double(text))
                        dismiss()
                    }.disabled(!isWeight && Double(text) == nil)
                }
            }
            .onAppear {
                guard !ready else { return }
                let today = store.data.body.first { $0.date == day }?[keyPath: dim.key]
                last = today ?? store.data.body.filter { $0.date <= day }.sorted { $0.date < $1.date }.last { $0[keyPath: dim.key] != nil }?[keyPath: dim.key]
                if isWeight { value = ((last ?? (store.weights().isEmpty ? 60 : store.latestWeight(day))) * 10).rounded() / 10 } else { text = today.map(fmt1) ?? ""; focused = true }
                ready = true
            }
        }.presentationDetents([.height(isWeight ? 320 : 280)])
    }
}

// 记 X 餐：顶部搜索食物库；搜不到时把关键词带进「快速记录」；不搜时是快速记录、复制以往、食物库
struct AddFoodView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let day: String
    @State var q = ""
    @State var meal: String
    @State var picked: Food?
    @State var manualName = ""
    @State var manualKcal = ""
    @State var limit = 20  // 食物库往下滑自动再加载 20 个
    @State var recorded = false

    init(day: String, meal: String = mealNow()) { self.day = day; _meal = State(initialValue: meal) }

    var body: some View {
        let all = store.searchFoods(q.trimmingCharacters(in: .whitespaces)), shown = Array(all.prefix(limit))
        NavigationStack {
            Form {
                Segmented(items: MEALS, label: { $0 }, selection: $meal).listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if !q.isEmpty && all.isEmpty {
                    Section { Text("食物库里没有「\(q)」，直接填热量记一笔").font(.footnote).foregroundStyle(Theme.ink7) }
                }
                if q.isEmpty || all.isEmpty { quick }
                if q.isEmpty { copySection }
                if !all.isEmpty {
                    Section(q.isEmpty ? "食物库" : "搜索结果") {
                        ForEach(shown) { f in
                            Button { picked = f } label: {
                                HStack { Text(f.name).foregroundStyle(Theme.ink); Spacer(); Text("\(fmt0(f.kcal)) kcal/100g").font(.footnote).foregroundStyle(Theme.ink7); Chevron() }
                            }.onAppear { if f.id == shown.last?.id, limit < all.count { limit += 20 } }
                        }
                    }
                }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索食物：米饭 / 鸡胸 / 海南鸡饭")
            .navigationTitle("记\(meal)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onChange(of: q) { _, v in limit = 20; if store.searchFoods(v.trimmingCharacters(in: .whitespaces)).isEmpty { manualName = v } }
            // 份量弹层关掉之后再关这一层：两层同时关，第二个会被系统忽略，停在「记 X 餐」上
            .sheet(item: $picked, onDismiss: { if recorded { dismiss() } }) { FoodAmountSheet(food: $0, day: day, meal: meal) { recorded = true } }
        }
    }

    var quick: some View {
        Section("快速记录（只填热量也行）") {
            HStack { TextField("热量", text: $manualKcal).keyboardType(.decimalPad); Text("kcal").foregroundStyle(Theme.ink7) }
            TextField("名称（选填）", text: $manualName)
            Button("记录到\(meal)") {
                guard let k = Double(manualKcal), k > 0 else { return }
                store.addLog(FoodLog(date: day, meal: meal, name: manualName.isEmpty ? "快速记录" : manualName, grams: 0, kcal: k, source: "manual")); dismiss()
            }.disabled((Double(manualKcal) ?? 0) <= 0)
        }
    }

    @ViewBuilder var copySection: some View {
        let recent = recentMeals()
        if !recent.isEmpty {
            Section("复制以往的\(meal)") {
                ForEach(recent, id: \.date) { g in
                    Button { store.copyLogs(g.logs, to: day, meal: meal); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(relDay(g.date)).foregroundStyle(Theme.ink); Spacer(); Text("\(fmt0(g.logs.reduce(0) { $0 + $1.kcal })) kcal · 复制").font(.footnote).foregroundStyle(Theme.accent) }
                            Text(g.logs.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(Theme.ink7).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    // 最近 7 天同一餐次的记录，按天分组、最新在前，最多 3 组
    func recentMeals() -> [(date: String, logs: [FoodLog])] {
        let from = dayKey(Calendar.current.date(byAdding: .day, value: -7, to: ISO.date(day)!)!)
        let ls = store.data.logs.filter { $0.meal == meal && $0.date < day && $0.date >= from }
        return Dictionary(grouping: ls, by: \.date).sorted { $0.key > $1.key }.prefix(3).map { (date: $0.key, logs: $0.value) }
    }
}

struct FoodAmountSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let food: Food, day: String, meal: String, done: () -> Void
    @State var grams = "100"

    var body: some View {
        let g = Double(grams) ?? 0, k = g / 100
        NavigationStack {
            Form {
                HStack { TextField("克数", text: $grams).keyboardType(.decimalPad).font(.title2.weight(.semibold)); Text("g").foregroundStyle(Theme.ink7) }
                Text("\(fmt0(food.kcal * k)) kcal（每 100g \(fmt0(food.kcal)) kcal）").foregroundStyle(Theme.ink7)
                if food.oily { Text("未含烹调油，炒菜可另加「烹调油」10g ≈ 90 kcal").font(.caption).foregroundStyle(Theme.ink7) }
            }
            .navigationTitle(food.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.addLog(FoodLog(date: day, meal: meal, name: food.name, grams: g, kcal: (food.kcal * k).rounded(),
                                             carb: food.carb * k, protein: food.protein * k, fat: food.fat * k, source: "db"))
                        dismiss(); done()
                    }.disabled(g <= 0)
                }
            }
        }.presentationDetents([.height(260)])
    }
}

// 改已记的食物：改克数按这一条原来的每克热量 / 营养素等比例换算；没有克数的（快速记录）直接改热量；可以换餐次、删除
struct LogEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let log: FoodLog
    @State var grams = ""
    @State var kcal = ""
    @State var meal = ""

    var body: some View {
        let g = Double(grams) ?? 0, k = log.grams > 0 && g > 0 ? g / log.grams : 1
        NavigationStack {
            Form {
                Segmented(items: MEALS, label: { $0 }, selection: $meal).listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                Section {
                    if log.grams > 0 {
                        LabeledContent("克数") { HStack { TextField("克", text: $grams).keyboardType(.decimalPad).multilineTextAlignment(.trailing); Text("g").foregroundStyle(Theme.ink7) } }
                        LabeledContent("热量", value: "\(fmt0(log.kcal * k)) kcal")
                    } else {
                        LabeledContent("热量") { HStack { TextField("kcal", text: $kcal).keyboardType(.decimalPad).multilineTextAlignment(.trailing); Text("kcal").foregroundStyle(Theme.ink7) } }
                    }
                } footer: { if log.grams > 0 { Text("按这一条每 100g \(fmt0(log.kcal / log.grams * 100)) kcal 换算") } }
                Section { Button("删除这一项", role: .destructive) { store.data.logs.removeAll { $0.id == log.id }; store.save(); dismiss() }.frame(maxWidth: .infinity) }
            }
            .navigationTitle(log.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let i = store.data.logs.firstIndex(where: { $0.id == log.id }) else { return dismiss() }
                        var l = log; l.meal = meal
                        if log.grams > 0 { l.grams = g; l.kcal = (log.kcal * k).rounded(); l.carb = log.carb * k; l.protein = log.protein * k; l.fat = log.fat * k }
                        else { l.kcal = Double(kcal) ?? log.kcal }
                        store.data.logs[i] = l; store.save(); dismiss()
                    }.disabled(log.grams > 0 ? g <= 0 : (Double(kcal) ?? 0) <= 0)
                }
            }
            .onAppear { grams = fmt1(log.grams); kcal = fmt1(log.kcal); meal = log.meal }
        }.presentationDetents([.medium])
    }
}

// 记录运动：左取消右保存，类型只写名称；editing = 改手动记的那一条（带删除）
struct AddWorkoutView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let day: String
    var editing: ManualWorkout? = nil
    static let types: [(String, Double)] = [("快走", 4.3), ("慢跑", 7.0), ("骑行", 6.8), ("游泳", 6.0), ("网球", 7.3), ("力量训练", 5.0), ("瑜伽", 2.5), ("爬楼", 8.0)]
    @State var idx = 0
    @State var minutes = "30"
    var body: some View {
        let (t, met) = Self.types[idx], m = Double(minutes) ?? 0
        let kcal = max(met - 1, 0) * store.latestWeight(day) * m / 60
        NavigationStack {
            Form {
                Picker("类型", selection: $idx) { ForEach(Self.types.indices, id: \.self) { Text(Self.types[$0].0) } }
                LabeledContent("分钟") { TextField("分钟", text: $minutes).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                LabeledContent("消耗", value: "约 \(fmt0(kcal)) kcal")
                if editing != nil {
                    Section { Button("删除这一项", role: .destructive) { store.data.workouts.removeAll { $0.id == editing?.id }; store.save(); dismiss() }.frame(maxWidth: .infinity) }
                }
            }
            .navigationTitle(editing == nil ? "记录运动" : "改运动").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var w = ManualWorkout(date: day, type: t, minutes: m, met: met, kcal: kcal.rounded())
                        if let e = editing { w.id = e.id; w.date = e.date; store.data.workouts.removeAll { $0.id == e.id } }
                        store.data.workouts.append(w); store.save(); dismiss()
                    }.disabled(m <= 0)
                }
            }
            .onAppear { if let e = editing { idx = Self.types.firstIndex { $0.0 == e.type } ?? 0; minutes = "\(Int(e.minutes))" } }
        }.presentationDetents([.medium])
    }
}

// MARK: 拍照算热量：识别走「我的 → AI 识别」里选的服务（各家 API 或 Mac 上的 boohee-lite）
// 结果合成一张卡：总热量 → 记到哪餐（按时间自动选）→ 由哪些组成；总热量 = 各项相加，显示值就是保存值；右上角「保存」

struct PhotoItem: Codable, Identifiable { var id: String { name }; var name: String; var grams: Double; var kcal: Double; var carb: Double?; var protein: Double?; var fat: Double?; var confidence: String }
struct PhotoEstimate: Codable { var items: [PhotoItem]; var oil_spoons: Double; var kcal_low: Int; var kcal_mid: Int; var kcal_high: Int; var confidence: String; var note: String; var photo_id: Int? }
struct PhotoEdit: Identifiable { let id: Int }  // 正在逐项修正的第几项
struct ServiceError: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

let CONF = ["high": "高", "medium": "中", "low": "低"]

struct PhotoEstimateView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let image: UIImage, day: String, manual: (String) -> Void  // manual：识别失败时去手动记这一餐
    @State var est: PhotoEstimate?
    @State var err: String?
    @State var meal = mealNow()
    @State var started = Date.now
    @State var refining = false
    @State var showFix = false
    @State var hint = ""
    @State var editing: PhotoEdit?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(uiImage: image).resizable().scaledToFill().frame(height: 200).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    if let e = est {
                        result(e).opacity(refining ? 0.4 : 1).disabled(refining)  // 重新识别时旧结果置灰保留，新结果出来再替换
                            .overlay { if refining { waiting("按你的说明重新识别") } }
                        if let err { Text(err).font(.footnote).foregroundStyle(Theme.danger) }
                    } else if let err {
                        failure(err)
                    } else {
                        Card { waiting("AI 识别中") }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            .background(Theme.page)
            .navigationTitle("拍照算热量").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { if let est { commit(est); dismiss() } }.disabled(est == nil || refining) }
            }
            .alert("告诉 AI 哪里认错了", isPresented: $showFix) {
                TextField("例：不是鸡蛋，是豆腐；米饭只有半碗", text: $hint)
                Button("重新识别") { Task { await refine() } }
                Button("取消", role: .cancel) {}
            } message: { Text("AI 会带着你的说明重新识别") }
            .sheet(item: $editing) { j in
                if let e = est, e.items.indices.contains(j.id) {
                    PhotoItemEditor(item: e.items[j.id]) { new in update { e in if let new { e.items[j.id] = new } else { e.items.remove(at: j.id) } } }
                }
            }
            .task { await estimate() }
        }
    }

    func result(_ e: PhotoEstimate) -> some View {
        Card {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(fmt0(Double(e.kcal_mid))).font(.bigNum).foregroundStyle(Theme.accent).monospacedDigit()
                    Text("kcal").font(.subheadline).foregroundStyle(Theme.ink7)
                }
                Text("区间 \(fmt0(Double(e.kcal_low)))–\(fmt0(Double(e.kcal_high))) · 置信度\(CONF[e.confidence] ?? e.confidence)").font(.caption).foregroundStyle(Theme.ink7)
                let c = e.items.compactMap(\.carb).reduce(0, +), p = e.items.compactMap(\.protein).reduce(0, +), f = e.items.compactMap(\.fat).reduce(0, +)
                if c + p + f > 0 { HStack { macro("碳水", c); macro("蛋白质", p); macro("脂肪", f) }.padding(.top, 6) }
            }.frame(maxWidth: .infinity)
            Segmented(items: MEALS, label: { $0 }, selection: $meal).padding(.vertical, 12)
            // 逐项：按热量从高到低；点一项改名称 / 克数 / 热量，合计跟着重算
            ForEach(e.items.indices.sorted { e.items[$0].kcal > e.items[$1].kcal }, id: \.self) { n in
                let i = e.items[n]
                Sep()
                CardRow(title: i.name, value: "\(fmt0(i.grams))g · \(fmt0(i.kcal)) kcal") { editing = PhotoEdit(id: n) }
                    .swipeToDelete { update { $0.items.remove(at: n) } }
            }
            Sep()
            HStack {
                Text("烹调油 \(Int(e.oil_spoons)) 勺").font(.subheadline).foregroundStyle(Theme.ink)
                Spacer()
                Text("≈ \(fmt0(e.oil_spoons * 90)) kcal").font(.footnote).foregroundStyle(Theme.ink7)
                HStack(spacing: 0) {
                    Button { update { $0.oil_spoons = max($0.oil_spoons - 1, 0) } } label: { Image(systemName: "minus").frame(width: 40, height: 32) }.disabled(e.oil_spoons <= 0)
                    Rectangle().fill(Theme.ink3).frame(width: 1, height: 16)
                    Button { update { $0.oil_spoons = min($0.oil_spoons + 1, 5) } } label: { Image(systemName: "plus").frame(width: 40, height: 32) }
                }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink).buttonStyle(.plain).background(Capsule().fill(Theme.page))
            }.frame(minHeight: 44)
            Text(e.note).font(.caption2).foregroundStyle(Theme.ink7).padding(.vertical, 8)
            Sep()
            Button { showFix = true } label: { Text("认错了？告诉 AI 重新识别").font(.footnote).foregroundStyle(Theme.accent).frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.plain).disabled(AIConfig(store.data.profile).provider == .mac && e.photo_id == nil)
        }
    }

    // 等待：显示已等了多少秒
    func waiting(_ t: String) -> some View {
        TimelineView(.periodic(from: started, by: 1)) { ctx in
            HStack(spacing: 12) {
                ProgressView()
                Text("\(t) · 已等 \(max(Int(ctx.date.timeIntervalSince(started)), 0)) 秒").font(.subheadline).foregroundStyle(Theme.ink7).monospacedDigit()
            }.frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    // 识别失败按原因分三类：连不上、没配好、没认出来；都给「手动记录」
    func failure(_ e: String) -> some View {
        let offline = e.contains("offline") || e.contains("网络连接") || e.contains("互联网")
        let (title, icon): (String, String) = offline ? ("没有网络，可以先手动记录", "wifi.slash")
            : e.contains("连不上") ? ("连不上识别服务", "wifi.exclamationmark")
            : e.contains("先在") || e.contains("地址") || e.contains("HTTP 40") || e.contains("接口") ? ("识别服务没配好", "gearshape")
            : ("没认出来", "questionmark.circle")
        return Card {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.title).foregroundStyle(Theme.warn)
                Text(title).font(.cardTitle).foregroundStyle(Theme.ink)
                Text(e).font(.caption).foregroundStyle(Theme.ink7).multilineTextAlignment(.center).lineLimit(4)
                HStack(spacing: 12) {
                    Button("重试") { Task { await estimate() } }.buttonStyle(PillButton(primary: false))
                    Button("手动记录") { manual(meal); dismiss() }.buttonStyle(PillButton())
                }.padding(.top, 4)
                if title == "识别服务没配好" { Button("去「我的 → AI 识别」") { store.tab = 0; dismiss() }.font(.footnote).foregroundStyle(Theme.accent) }
            }.frame(maxWidth: .infinity)
        }
    }

    // 逐项修正后按同一口径重算合计：烹调油每勺 10g × 8.99，区间沿用整体置信度的浮动比例（同 AI.estimate）
    func update(_ f: (inout PhotoEstimate) -> Void) {
        guard var e = est else { return }
        f(&e)
        let total = e.items.reduce(0) { $0 + $1.kcal } + e.oil_spoons * 10 * 8.99, r = AI.range[e.confidence] ?? 0.25
        e.kcal_low = r10(total * (1 - r)); e.kcal_mid = r10(total); e.kcal_high = r10(total * (1 + r))
        est = e
    }

    func macro(_ t: String, _ g: Double) -> some View {
        VStack(spacing: 2) { Text("\(Int(g))g").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).monospacedDigit(); Text(t).font(.caption2).foregroundStyle(Theme.ink7) }.frame(maxWidth: .infinity)
    }

    func estimate() async {
        err = nil; est = nil; started = .now
        let c = AIConfig(store.data.profile)
        do {
            if c.provider == .mac {
                guard let jpg = image.jpegData(compressionQuality: 0.7) else { err = "照片读取失败"; return }
                est = try await post("/api/photo", ["image": "data:image/jpeg;base64," + jpg.base64EncodedString()])
            } else {
                est = try await AI.recognize(image, config: c, foods: store.data.foods)
            }
        } catch { err = error.localizedDescription }
    }

    func refine() async {
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines), c = AIConfig(store.data.profile)
        guard let e = est, !h.isEmpty else { return }
        refining = true; err = nil; started = .now
        do {
            if c.provider == .mac {
                guard let id = e.photo_id else { throw ServiceError("这次结果没有照片编号，重新拍一张再修正") }
                est = try await post("/api/photo/refine", ["photo_id": id, "hint": h])
            } else {
                est = try await AI.recognize(image, config: c, foods: store.data.foods, hint: h, previous: e.items)
            }
            hint = ""
        } catch { err = "重新识别失败：\(error.localizedDescription)" }
        refining = false
    }

    // Mac 服务出错时回 {"error": ...}（地址缺令牌是 403），把原因原样显示，不笼统地说连不上
    func post(_ path: String, _ body: [String: Any]) async throws -> PhotoEstimate {
        let base = store.data.profile.photoServer.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + path) else { throw ServiceError("服务地址无效，到「我的 → AI 识别」里改") }
        var req = URLRequest(url: url, timeoutInterval: 240)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let res: (Data, URLResponse)
        do { res = try await URLSession.shared.data(for: req) } catch { throw ServiceError("连不上识别服务：\(error.localizedDescription)") }
        let (d, r) = res, code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw ServiceError(code == 404 ? "识别服务没有 \(path) 接口，把 Mac 上的 boohee-lite 更新到最新" : msg ?? "识别服务返回 HTTP \(code)")
        }
        return try JSONDecoder().decode(PhotoEstimate.self, from: d)
    }

    // 显示的就是保存的：各项原样记，烹调油单独一条
    func commit(_ e: PhotoEstimate) {
        var items = e.items.map { ($0.name, $0.grams, $0.kcal, $0.carb ?? 0, $0.protein ?? 0, $0.fat ?? 0) }
        if e.oil_spoons > 0 { items.append(("烹调油", e.oil_spoons * 10, (e.oil_spoons * 10 * 8.99).rounded(), 0, 0, e.oil_spoons * 10)) }
        for i in items {
            store.addLog(FoodLog(date: day, meal: meal, name: i.0, grams: i.1, kcal: i.2.rounded(), carb: i.3, protein: i.4, fat: i.5, source: "photo"))
        }
    }
}

// 修正这一项：热量默认显示换算值（标「自动」：改克数按这一项原来的每克热量等比例换算，改了名称且食物库里有就按库重算）
// 点热量行改成手动（标「手动」），之后改克数不再换算
struct PhotoItemEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let item: PhotoItem, save: (PhotoItem?) -> Void  // nil = 删除这一项
    @State var name: String
    @State var grams: String
    @State var kcal = ""
    @State var manual = false
    @FocusState var focus: Int?

    init(item: PhotoItem, save: @escaping (PhotoItem?) -> Void) {
        self.item = item; self.save = save; _name = State(initialValue: item.name); _grams = State(initialValue: "\(Int(item.grams))")
    }

    var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    var food: Food? { trimmed == item.name ? nil : findFood(trimmed, in: store.data.foods) }
    var result: PhotoItem {
        let g = Double(grams) ?? item.grams
        var r = item; r.name = trimmed; r.grams = g
        if let f = food {
            r.kcal = (f.kcal * g / 100).rounded(); r.carb = AI.r1(f.carb * g / 100); r.protein = AI.r1(f.protein * g / 100); r.fat = AI.r1(f.fat * g / 100)
        } else if item.grams > 0 {
            let k = g / item.grams
            r.kcal = (item.kcal * k).rounded(); r.carb = item.carb.map { AI.r1($0 * k) }; r.protein = item.protein.map { AI.r1($0 * k) }; r.fat = item.fat.map { AI.r1($0 * k) }
        }
        if manual, let k = Double(kcal) { r.kcal = k.rounded() }
        return r
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("名称", 0) { TextField("食物名称", text: $name) }
                    field("克数", 1) { HStack(spacing: 4) { TextField("克", text: $grams).keyboardType(.decimalPad); Text("g").foregroundStyle(Theme.ink7) } }
                    if manual {
                        field("热量", 2, tag: "手动") { HStack(spacing: 4) { TextField("kcal", text: $kcal).keyboardType(.numberPad); Text("kcal").foregroundStyle(Theme.ink7) } }
                    } else {
                        Button { kcal = "\(Int(result.kcal))"; manual = true; focus = 2 } label: {
                            HStack { Text("热量").foregroundStyle(Theme.ink); Spacer(); Tag("自动"); Text("\(fmt0(result.kcal)) kcal").foregroundStyle(Theme.ink7).monospacedDigit(); Chevron() }
                        }
                    }
                } footer: { if manual { Text("热量按你填的算，改克数不再换算。") } }
                Section { Button("删除这一项", role: .destructive) { save(nil); dismiss() }.frame(maxWidth: .infinity) }
            }
            .navigationTitle("修正这一项").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(result); dismiss() }.disabled(trimmed.isEmpty || Double(grams) == nil) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // 可改的行：右对齐输入框 + 箭头，点整行聚焦
    func field<F: View>(_ t: String, _ n: Int, tag: String? = nil, @ViewBuilder _ input: () -> F) -> some View {
        HStack {
            Text(t).foregroundStyle(Theme.ink)
            Spacer()
            if let tag { Tag(tag) }
            input().multilineTextAlignment(.trailing).foregroundStyle(Theme.ink7).focused($focus, equals: n).fixedSize()
            Chevron()
        }.contentShape(Rectangle()).onTapGesture { focus = n }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController(); c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        c.delegate = context.coordinator; return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(self) }
    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let p: CameraPicker; init(_ p: CameraPicker) { self.p = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            p.image = info[.originalImage] as? UIImage; p.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { p.dismiss() }
    }
}

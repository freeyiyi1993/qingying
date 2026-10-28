import SwiftUI

// MARK: 目标：减重方案（模块标题旁是方案下拉；整张卡可点进入调整方案）+ 辅助目标（喝水、睡眠、力量训练、蛋白质：保证基础代谢）
// 体重趋势图在趋势页；目标体重、每日缺口、运动吃回、四个辅助目标都在方案里设置（设计稿 03 / 03b / Journey C5 D5 D6）

let WEIGHT_VALUES = (300...1500).map { Double($0) / 10 }, WATER_VALUES = stride(from: 1000.0, through: 4000, by: 250).map { $0 }
let SLEEP_VALUES = stride(from: 5.0, through: 10, by: 0.5).map { $0 }, EAT_BACK_VALUES = [0, 0.3, 0.5, 0.6, 0.8, 1.0]
let STRENGTH_VALUES = (0...7).map(Double.init), PROTEIN_VALUES = stride(from: 0.8, through: 2.0, by: 0.1).map { ($0 * 10).rounded() / 10 }

struct GoalView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var health: HealthService
    @State var editing = false
    @State var confirmEnd = false
    @State var confirmDelete = false
    @State var auxGoal: AuxKind?
    @State var planID: String?  // 方案下拉选中的；nil = 当前方案（没有当前方案时是最近结束的那个）

    var body: some View {
        let plans = store.allPlans, shown = plans.first { $0.id == planID } ?? plans.first
        let now = shown.flatMap { p in store.trend().points.last { $0.date <= (p.ended ?? dayKey()) }?.trend }  // 已结束的方案按结束那天的趋势体重算
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("减重方案").font(.headline).foregroundStyle(Theme.ink7)
                        if !plans.isEmpty { PlanPicker(plans: plans, all: nil, pick: Binding(get: { shown?.id }, set: { planID = $0 })) }
                    }.padding(.leading, 16)
                    if let shown {
                        Card {
                            PlanCard(plan: shown, now: now).contentShape(Rectangle())
                                .onTapGesture { if shown.ended == nil { editing = true } }  // 历史方案只读
                            if shown.ended == nil {
                                Sep().padding(.top, 12)
                                HStack {
                                    Button("调整方案") { editing = true }.foregroundStyle(Theme.ink)
                                    Spacer()
                                    Button("结束方案") { confirmEnd = true }.foregroundStyle(Theme.danger)
                                }.font(.subheadline).buttonStyle(.plain).frame(minHeight: 44).padding(.bottom, -12)
                            } else {
                                Sep().padding(.top, 12)
                                Button("删除方案") { confirmDelete = true }.foregroundStyle(Theme.danger)
                                    .font(.subheadline).buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 44).padding(.bottom, -12)
                            }
                        }
                    } else {
                        Card {  // 还没有方案：说明方案会影响记录页的预算
                            VStack(spacing: 10) {
                                Image(systemName: "flag.checkered").font(.title).foregroundStyle(Theme.accent)
                                Text("还没有减重方案").font(.cardTitle).foregroundStyle(Theme.ink)
                                Text("定一个目标体重和每天的热量缺口，记录页的预算会跟着算").font(.footnote).foregroundStyle(Theme.ink7).multilineTextAlignment(.center)
                                Button { editing = true } label: { Text("制定方案").frame(maxWidth: .infinity) }.buttonStyle(PillButton()).padding(.top, 4)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    if store.data.plan == nil, shown != nil {
                        Button { editing = true } label: { Text("制定新方案").frame(maxWidth: .infinity) }.buttonStyle(PillButton()).padding(.top, 8)
                    }
                    SectionTitle("辅助目标 · 保证基础代谢").padding(.leading, 20).padding(.top, 16)
                    Card(v: 4) { aux }
                }.padding(16)
            }
            .background(Theme.page)
            .toolbar(.hidden, for: .navigationBar).statusBarCover()
            .sheet(isPresented: $editing, onDismiss: { planID = nil }) { PlanEditor() }  // 定好新方案回到当前方案
            .sheet(item: $auxGoal) { k in AuxGoalSheet(kind: k) }
            .alert("结束这个方案？", isPresented: $confirmEnd) {
                Button("结束方案", role: .destructive) { store.endPlan(); planID = nil }
                Button("取消", role: .cancel) {}
            } message: { Text("结束后记录页不再按方案算预算，方案和记录会保留，可以在下拉里查看。") }
            .alert("删除这个方案？", isPresented: $confirmDelete) {
                Button("删除方案", role: .destructive) { if let id = shown?.id { store.deletePlan(id) }; planID = nil }
                Button("取消", role: .cancel) {}
            } message: { Text("只删除方案，这段时间的饮食、体重等记录都会保留。") }
            .onAppear { if LAUNCH_SHEET == "plan" { editing = true } }
        }
    }

    // 四项都显示「方案期内达标」：从方案开始到今天，喝水、睡眠、蛋白质按天，力量训练按周；没有方案时看最近 7 天 / 4 周
    @ViewBuilder var aux: some View {
        let p = store.data.profile, today = dayKey(), plan = store.data.plan
        let days = plan.map { daysBetween($0.start, today) } ?? lastDays(7), label = plan == nil ? "近 7 天达标" : "方案期内达标"
        let weeks = stride(from: 0, to: max(days.count, 1), by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let wks = plan == nil ? stride(from: 0, to: 28, by: 7).map { Array(lastDays(28)[$0..<$0 + 7]) } : weeks
        let wg = p.waterGoal ?? 2000, sg = p.sleepGoal ?? 7.5, tg = p.strengthGoal ?? 2, pg = store.proteinGoalGrams
        let thisWeek = store.strength(plan == nil ? lastDays(7) : weeks.last ?? [])
        AuxRow(icon: "drop.fill", color: Theme.water, title: "喝水", value: "\(fmt0(store.water(today))) / \(fmt0(wg)) ml", progress: store.water(today) / wg,
               hit: "\(label) \(days.filter { store.water($0) >= wg }.count)/\(days.count) 天") { auxGoal = .water }
        Sep(inset: 36)
        AuxRow(icon: "bed.double.fill", color: Theme.sleep, title: "睡眠", value: store.sleep(today).map { String(format: "%.1f / %.1f 小时", $0, sg) } ?? "去记录",
               progress: (store.sleep(today) ?? 0) / sg, hit: "\(label) \(days.filter { (store.sleep($0) ?? 0) >= sg }.count)/\(days.count) 天") { auxGoal = .sleep }
        Sep(inset: 36)
        AuxRow(icon: "dumbbell.fill", color: Theme.accent, title: "力量训练", value: "本周 \(thisWeek) / \(Int(tg)) 次", progress: Double(thisWeek) / max(tg, 1),
               hit: "\(plan == nil ? "近 4 周达标" : label) \(wks.filter { store.strength($0) >= Int(tg) }.count)/\(wks.count) 周") { auxGoal = .strength }
        Sep(inset: 36)
        AuxRow(icon: "fish.fill", color: Theme.warn, title: "蛋白质", value: "\(fmt0(store.protein(today))) / \(fmt0(pg)) g", progress: store.protein(today) / pg,
               hit: "\(label) \(days.filter { store.protein($0) >= pg }.count)/\(days.count) 天") { auxGoal = .protein }
    }
}

enum AuxKind: String, Identifiable { case water, sleep, strength, protein; var id: String { rawValue } }

struct AuxRow: View {
    let icon: String, color: Color, title: String, value: String, progress: Double, hit: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(title).font(.subheadline).foregroundStyle(Theme.ink); Spacer(); Text(value).font(.footnote).foregroundStyle(Theme.ink7).monospacedDigit() }
                    ProgressBar(value: progress, tint: color)
                    Text(hit).font(.caption2).foregroundStyle(Theme.ink7).monospacedDigit()
                }
                Chevron()
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// 辅助目标的滚轮：喝水 ml、睡眠小时、力量训练每周次数、蛋白质每公斤体重克数（右侧带算出来的克数）
struct AuxGoalSheet: View {
    @EnvironmentObject var store: Store
    let kind: AuxKind
    var body: some View {
        let w = store.weights().last?.weight ?? 60
        switch kind {
        case .water: GoalWheelSheet(title: "每天喝水", values: WATER_VALUES, format: { "\(fmt0($0)) ml" }, value: goal(\.waterGoal, 2000))
        case .sleep: GoalWheelSheet(title: "每晚睡眠", values: SLEEP_VALUES, format: { String(format: "%.1f 小时", $0) }, value: goal(\.sleepGoal, 7.5))
        case .strength: GoalWheelSheet(title: "每周力量训练", values: STRENGTH_VALUES, format: { "\(Int($0)) 次" }, value: goal(\.strengthGoal, 2))
        case .protein: GoalWheelSheet(title: "每天蛋白质", values: PROTEIN_VALUES, format: { String(format: "%.1f g/kg ≈ %d g", $0, Int(($0 * w / 5).rounded() * 5)) }, value: goal(\.proteinGoal, 1.2))
        }
    }
    func goal(_ k: WritableKeyPath<Profile, Double?>, _ d: Double) -> Binding<Double> {
        Binding(get: { store.data.profile[keyPath: k] ?? d }, set: { store.data.profile[keyPath: k] = $0; store.save() })
    }
}

// 方案卡：右上第 n/N 周（已结束标签）；左初始、右目标，中间半圆进度和「已减 · kg」
struct PlanCard: View {
    let plan: Plan, now: Double?

    var body: some View {
        let lost = now.map { plan.startWeight - $0 } ?? 0, need = plan.startWeight - plan.target
        let progress = need > 0 ? min(max(lost / need, 0), 1) : 0, cal = Calendar.current
        let weeks = Int((Double(max(cal.dateComponents([.day], from: ISO.date(plan.start)!, to: ISO.date(plan.end)!).day ?? 1, 1)) / 7).rounded(.up))
        let week = (cal.dateComponents([.day], from: ISO.date(plan.start)!, to: cal.startOfDay(for: .now)).day ?? 0) / 7 + 1
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Spacer()
                if plan.ended == nil { Text("第 \(min(week, weeks))/\(weeks) 周").font(.footnote).foregroundStyle(Theme.ink7).monospacedDigit(); Chevron() } else { Tag("已结束") }
            }
            HStack(alignment: .center, spacing: 0) {
                col(String(format: "%.1f", plan.startWeight), "初始")
                SemiGauge(progress: progress, value: fmt1((max(lost, 0) * 10).rounded() / 10), label: "已减 · kg")
                col(String(format: "%.1f", plan.target), "目标")
            }
        }
    }

    func col(_ v: String, _ t: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.sideNum).foregroundStyle(Theme.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(t).font(.caption2).foregroundStyle(Theme.ink7)
        }.frame(maxWidth: .infinity)
    }
}

// 半圆进度：直径 150（含线宽 12），页面底色轨道 + 品牌绿进度；中间 44 号核心数字
struct SemiGauge: View {
    let progress: Double, value: String, label: String
    let r: CGFloat = 69, line: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().trim(from: 0.5, to: 1).stroke(Theme.page, style: StrokeStyle(lineWidth: line, lineCap: .round))
            Circle().trim(from: 0.5, to: 0.5 + 0.5 * progress).stroke(Theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
        }
        .frame(width: 2 * r, height: 2 * r)
        .padding(.top, line / 2)  // 给弧顶描边的外半边留位置
        .frame(width: 2 * r + line, height: r + line, alignment: .top)  // 只露上半圆；两端的圆头往下伸出半个线宽
        .clipped()
        // 数字和单位贴底放，不跟着弧一起被裁
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                Text(value).font(.bigNum).monospacedDigit().foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.caption2).foregroundStyle(Theme.ink7)
            }.frame(maxWidth: 2 * (r - line))
        }
        .animation(.snappy, value: progress)
    }
}

// 方案下拉（目标页、趋势页共用）：用日期范围标识方案；all 是「全部记录」那一项的文字（选它 = nil），目标页不传
struct PlanPicker: View {
    let plans: [Plan], all: String?
    @Binding var pick: String?
    var body: some View {
        Menu {
            Picker("方案", selection: $pick) {
                if let all { Text(all).tag(String?.none) }
                ForEach(plans) { Text($0.range + ($0.ended == nil ? "" : "（已结束）")).tag(Optional($0.id)) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(plans.first { $0.id == pick }?.range ?? all ?? "").monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }.font(.headline).foregroundStyle(Theme.accent)
        }
        .buttonStyle(.borderless)
    }
}

// 调整方案 = 归档旧方案、从今天按起点体重开一个新方案（PlanEditor.save → startPlan）
// 先定目标，热量缺口模块在「要减 / 大约 / 预计达成」上面：「大约」/「预计达成」改了按时间自动算缺口（自动），直接输入缺口则倒推时间（手动）；每周减 = 缺口 × 7 / 7700
struct PlanEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var start = 0.0  // 起点体重：默认 7 日趋势，可以改
    @State var target = 0.0
    @State var days = 56  // 方案天数（自动时由它算缺口）
    @State var deficitText = ""
    @State var auto = true
    @State var eatBack = 0.6
    @State var sleep = 7.5
    @State var water = 2000.0
    @State var strength = 2.0
    @State var protein = 1.2
    @State var ready = false
    @State var sheet: EditorSheet?
    @State var warn: Double?  // 超出建议范围的缺口，弹窗
    @FocusState var typing: Bool

    enum EditorSheet: String, Identifiable { case start, weeks, end, sleep, water, strength, protein; var id: String { rawValue } }

    var need: Double { start - target }
    var deficit: Double { auto ? (need > 0 ? need * KCAL_PER_KG / Double(max(days, 1)) : 0) : (Double(deficitText) ?? 0) }
    var span: Int { auto ? days : (deficit > 0 ? Int((need * KCAL_PER_KG / deficit).rounded(.up)) : 0) }  // 手动输入缺口时倒推天数

    var body: some View {
        let h = store.data.profile.heightCm / 100, bmi = target / (h * h), trend = store.trend().points.last?.trend
        let end = Calendar.current.date(byAdding: .day, value: span, to: .now) ?? .now, ok = need > 0 && deficit > 0
        let outside = ok && !DEFICIT_RANGE.contains(deficit.rounded())
        NavigationStack {
            Form {
                Section("当前体重") {
                    CardRow(title: trend == nil ? "起点体重" : "7 日趋势", value: start > 0 ? String(format: "%.1f kg", start) : "去记录",
                            tag: trend.flatMap { abs($0 - start) > 0.05 ? "手动" : nil }) { sheet = .start }
                }
                Section("目标体重") {
                    VStack(spacing: 8) {
                        Text(String(format: "%.1f kg", target)).font(.num30).monospacedDigit()
                            .foregroundStyle(bmi < 18.5 ? Theme.warn : Theme.accent).contentTransition(.numericText(value: target))
                        if ready { RulerPicker(value: $target, range: 35...150, step: 0.1) }
                        if bmi < 18.5 { Label(String(format: "目标体重过轻（BMI %.1f）", bmi), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warn) }
                    }.frame(maxWidth: .infinity)
                }
                Section("热量缺口") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Text("每日缺口").foregroundStyle(Theme.ink)
                            Spacer()
                            Tag(auto ? "自动" : "手动")
                            TextField("0", text: Binding(get: { auto ? (need > 0 ? "\(r10(deficit))" : "") : deficitText }, set: { deficitText = $0; auto = false }))
                                .keyboardType(.numberPad).multilineTextAlignment(.center).focused($typing).font(.body.monospacedDigit())
                                .foregroundStyle(outside ? Theme.warn : Theme.ink).frame(width: 72, height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.ink3, lineWidth: 1))
                            Text("kcal").foregroundStyle(Theme.ink7)
                        }
                        Text(auto ? "按下面「大约」自动算 · 建议 200–500" : "手动输入 · 建议 200–500").font(.caption2).foregroundStyle(outside ? Theme.warn : Theme.ink7)
                    }.padding(.vertical, 4)
                    Picker("运动吃回", selection: $eatBack) { ForEach(EAT_BACK_VALUES, id: \.self) { Text("\(Int($0 * 100))%").tag($0) } }
                }
                Section {
                    if need <= 0 {
                        Text(start > 0 ? String(format: "目前只支持减重方案，目标要低于当前 %.1f kg", start) : "先记一个起点体重").foregroundStyle(Theme.warn)
                    } else {
                        CardRow(title: "要减", value: String(format: "%.1f kg（约每周 %.2f kg）", need, deficit * 7 / KCAL_PER_KG))
                        CardRow(title: "大约", value: "\(Int((Double(span) / 7).rounded(.up))) 周") { sheet = .weeks }
                        CardRow(title: "预计达成", value: "\(dayKey(end).prefix(4)) 年 \(monthDay(end))") { sheet = .end }
                    }
                }
                Section {
                    CardRow(title: "睡眠", value: String(format: "每晚 %.1f 小时", sleep)) { sheet = .sleep }
                    CardRow(title: "喝水", value: "每天 \(fmt0(water)) ml") { sheet = .water }
                    CardRow(title: "力量训练", value: "每周 \(Int(strength)) 次") { sheet = .strength }
                    CardRow(title: "蛋白质", value: "每天 \(fmt0((protein * max(start, 30) / 5).rounded() * 5)) g") { sheet = .protein }
                } header: { Text("基础代谢保障") } footer: {
                    if need > 0 { Text("点「开始」后按 \(String(format: "%.1f", start)) kg 从今天重新开始，旧方案可在下拉里查看。") }
                }
            }
            .environment(\.inForm, true)
            .navigationTitle(store.data.plan == nil ? "制定方案" : "调整方案").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("开始") { save(end) }.disabled(!ok) }
                ToolbarItem(placement: .keyboard) { HStack { Spacer(); Button("完成") { typing = false } } }
            }
            .onChange(of: typing) { _, t in if !t && !auto { check() } }
            .alert(warn.map { $0 > DEFICIT_RANGE.upperBound ? "目标太激进" : "进度太慢" } ?? "", isPresented: Binding(get: { warn != nil }, set: { if !$0 { warn = nil } })) {
                let edge = (warn ?? 0) > DEFICIT_RANGE.upperBound ? DEFICIT_RANGE.upperBound : DEFICIT_RANGE.lowerBound
                Button("改回 \(Int(edge))") { deficitText = "\(Int(edge))"; auto = false; warn = nil }
                Button("仍然使用", role: .cancel) { warn = nil }
            } message: {
                Text("每天缺口 \(r10(warn ?? 0)) kcal，建议在 200–500 之间。\((warn ?? 0) > DEFICIT_RANGE.upperBound ? "缺口太大容易掉肌肉、反弹" : "缺口太小体重几乎不动")")
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .start: StartWeightSheet(value: $start)
                case .weeks: GoalWheelSheet(title: "大约几周", values: (1...104).map(Double.init), format: { "\(Int($0)) 周" },
                                            value: Binding(get: { (Double(span) / 7).rounded(.up) }, set: { days = Int($0) * 7; auto = true; checkLater() }))
                case .end: EndDateSheet(date: end) { d in days = max(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: d).day ?? 1, 1); auto = true; checkLater() }
                case .sleep: GoalWheelSheet(title: "每晚睡眠", values: SLEEP_VALUES, format: { String(format: "%.1f 小时", $0) }, value: $sleep)
                case .water: GoalWheelSheet(title: "每天喝水", values: WATER_VALUES, format: { "\(fmt0($0)) ml" }, value: $water)
                case .strength: GoalWheelSheet(title: "每周力量训练", values: STRENGTH_VALUES, format: { "\(Int($0)) 次" }, value: $strength)
                case .protein: GoalWheelSheet(title: "每天蛋白质", values: PROTEIN_VALUES, format: { String(format: "%.1f g/kg ≈ %d g", $0, Int(($0 * start / 5).rounded() * 5)) }, value: $protein)
                }
            }
            .onAppear {
                guard !ready else { return }
                let p = store.data.profile
                start = ((trend ?? store.weights().last?.weight ?? 0) * 10).rounded() / 10  // 起点用 7 日趋势体重，和之后的对比同口径
                target = store.data.plan?.target ?? p.targetWeight
                eatBack = EAT_BACK_VALUES.min { abs($0 - p.eatBack) < abs($1 - p.eatBack) }!
                sleep = p.sleepGoal ?? 7.5; water = p.waterGoal ?? 2000; strength = p.strengthGoal ?? 2; protein = p.proteinGoal ?? 1.2
                // 按原来的每日缺口换算成整周数，之后「自动」按周数算缺口
                if need > 0 { days = max(Int((need * KCAL_PER_KG / p.deficitGoal / 7).rounded(.up)), 1) * 7 }
                ready = true
            }
        }
    }

    // 缺口超出 200–500 弹窗
    func check() { if need > 0, deficit > 0, !DEFICIT_RANGE.contains(deficit.rounded()) { warn = deficit } }
    func checkLater() { Task { try? await Task.sleep(for: .milliseconds(600)); check() } }  // 等滚轮弹层关掉再弹窗，否则弹不出来

    func save(_ end: Date) {
        let t = (target * 10).rounded() / 10, s = (start * 10).rounded() / 10
        var p = store.data.profile
        p.targetWeight = t; p.deficitGoal = Double(r10(deficit)); p.eatBack = eatBack
        p.sleepGoal = sleep; p.waterGoal = water; p.strengthGoal = strength; p.proteinGoal = protein
        store.data.profile = p
        if store.weights().isEmpty { store.setBody(dayKey(), \.weight, s) }  // 还没有任何体重：起点就记成今天的体重
        store.startPlan(Plan(start: dayKey(), startWeight: s, target: t, end: dayKey(end)))  // 旧方案自动归档
        dismiss()
    }
}

// 起点体重：刻度尺（同「记录 → 身体 → 体重」）
struct StartWeightSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var value: Double
    @State var v = 60.0
    @State var ready = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", v)).font(.bigNum).monospacedDigit().contentTransition(.numericText(value: v))
                    Text("kg").font(.title3).foregroundStyle(Theme.ink7)
                }.foregroundStyle(Theme.accent)
                if ready { RulerPicker(value: $v, range: 25...200, step: 0.1) }
                Text("方案的起点。默认是 7 日趋势体重，近几天称重有异常时可以改").font(.footnote).foregroundStyle(Theme.ink7).multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("起点体重").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { value = (v * 10).rounded() / 10; dismiss() } }
            }
            .onAppear { if !ready { v = value > 0 ? value : 60; ready = true } }
        }.presentationDetents([.height(320)])
    }
}

struct EndDateSheet: View {
    @Environment(\.dismiss) var dismiss
    @State var date: Date
    let done: (Date) -> Void
    var body: some View {
        NavigationStack {
            DatePicker("预计达成", selection: $date, in: Calendar.current.date(byAdding: .day, value: 7, to: .now)!..., displayedComponents: .date)
                .datePickerStyle(.graphical).padding(.horizontal)
                .navigationTitle("预计达成").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { done(date); dismiss() } }
                }
        }.presentationDetents([.medium])
    }
}

// 滚轮选数值（体重、喝水目标、睡眠目标）
struct WheelPicker: View {
    let values: [Double], format: (Double) -> String
    @Binding var value: Double
    var body: some View {
        Picker("", selection: Binding(get: { values.min { abs($0 - value) < abs($1 - value) } ?? value }, set: { value = $0 })) {
            ForEach(values, id: \.self) { Text(format($0)).tag($0) }
        }.pickerStyle(.wheel).frame(height: 130)
    }
}

struct GoalWheelSheet: View {
    @Environment(\.dismiss) var dismiss
    let title: String, values: [Double], format: (Double) -> String
    @Binding var value: Double
    @State var pick = 0.0
    var body: some View {
        NavigationStack {
            WheelPicker(values: values, format: format, value: $pick).padding(.horizontal)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { value = pick; dismiss() } }
                }
                .onAppear { pick = value }
        }.presentationDetents([.height(260)])
    }
}

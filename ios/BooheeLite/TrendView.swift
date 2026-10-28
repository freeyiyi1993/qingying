import SwiftUI
import Charts

// MARK: 趋势：方案下拉 → 体重（计划线 + 结论）→ 围度 → 热量缺口 → 喝水 / 睡眠 → 力量训练 / 蛋白质 → 步数 → 全部身体数据；按住拖动看当天
// 选了方案：横轴铺满方案开始到结束，竖线标出今天，不用滑动；全部记录：一屏 30 天，左右滑看更早，几张图一起滑（设计稿 04）

let VISIBLE: TimeInterval = 30 * 86400

struct TrendView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var health: HealthService
    @State var scrollX = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now))!  // 全部记录时一屏的左边界，几张图共用
    @State var planID = ""  // 方案下拉：""= 跟随当前方案，"all" = 全部记录，其余是方案 id
    @State var selW: Date?
    @State var selGirth: Date?
    @State var part = "腰围"

    var body: some View {
        let t = store.trend(), target = store.data.profile.targetWeight, today = dayKey(), plans = store.allPlans
        let pickID = planID == "" ? store.data.plan?.id : planID == "all" ? nil : planID
        let plan = plans.first { $0.id == pickID }
        // 全部记录：最早一条记录（至少往前 30 天）到今天；选了方案：方案开始到结束（已结束的数据到结束那天）
        let firsts = [t.points.first?.date, store.data.body.map(\.date).min(), store.data.logs.map(\.date).min(), store.data.estimates?.map(\.date).min(),
                      store.data.waters?.map(\.date).min(), store.data.sleeps?.map(\.date).min(), dayKey(scrollX)].compactMap { $0 }
        let start = plan?.start ?? firsts.min()!, last = plan?.ended ?? today, days = daysBetween(start, last)
        let from = ISO.date(start)!, to = plan.map { max(ISO.date($0.end)!, ISO.date(last)!) } ?? .now
        let ax = Axis(from: from, to: to, scroll: plan == nil, today: plan?.ended == nil && plan != nil)
        let g = GIRTHS.first { $0.name == part } ?? GIRTHS[1]
        let girths = store.data.body.compactMap { b in b[keyPath: g.key].map { (date: b.date, cm: $0) } }.filter { $0.date >= start && $0.date <= last }.sorted { $0.date < $1.date }
        let goal = store.data.profile.deficitGoal, waterGoal = store.data.profile.waterGoal ?? 2000, sleepGoal = store.data.profile.sleepGoal ?? 7.5
        let balances = store.balances(days), past = days.filter { $0 < today }
        let water = days.compactMap { d in let v = store.water(d); return v > 0 ? Bar(date: d, value: v) : nil }
        let sleep = days.compactMap { d in store.sleep(d).map { Bar(date: d, value: $0) } }
        let strength = days.compactMap { d in let n = store.strength([d]); return n > 0 ? Bar(date: d, value: Double(n)) : nil }
        let protein = days.compactMap { d in let v = store.protein(d); return v > 0 ? Bar(date: d, value: v) : nil }
        let steps = days.compactMap { d in store.steps(d).map { Bar(date: d, value: $0) } }
        let pts = t.points.filter { $0.date >= start && $0.date <= last }
        let avgDeficit = avg7(balances.filter { $0.date < today }.map { Bar(date: $0.date, value: $0.burn - $0.intake) })
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !plans.isEmpty {
                        HStack(spacing: 8) {
                            Text("减重方案").font(.headline).foregroundStyle(Theme.ink7)
                            PlanPicker(plans: plans, all: "全部记录", pick: Binding(get: { pickID }, set: { planID = $0 ?? "all" }))
                        }.padding(.leading, 16)
                    }
                    card("体重", weightLine(t, plan)) { weightChart(pts, t.points.count, target, ax, plan) }
                    card("围度", girths.last.map { l in "当前 \(fmt1(l.cm)) cm" + (girths.count > 1 ? " · 较开始 \(signed(l.cm - girths[0].cm)) cm" : "") }) {
                        Segmented(items: GIRTHS.map(\.name), label: { n in GIRTHS.first { $0.name == n }!.short }, selection: $part)
                        girthChart(girths, ax, g.name)
                    }
                    card("热量缺口", avgDeficit.map { "近 7 天均 \(fmt0($0)) kcal" + (store.data.plan != nil ? " · 较计划 \(signed($0 - goal, "%.0f")) kcal" : "") }) {
                        BalanceChart(rows: balances, ax: ax, scrollX: $scrollX)
                    }
                    card("喝水", "今天 \(fmt0(store.water(today))) / \(fmt0(waterGoal)) ml") {
                        BarChart(bars: water, ax: ax, goal: waterGoal, empty: ("还没有喝水记录", "在「记录 → 作息运动」里记"),
                                 tint: Theme.water, unit: "ml", label: { "\(fmt0($0.value)) ml" }, scrollX: $scrollX)
                    }
                    card("睡眠", avg7(sleep.filter { $0.date <= today }).map { String(format: "近 7 天平均 %.1f 小时", $0) }) {
                        BarChart(bars: sleep, ax: ax, goal: sleepGoal, empty: ("没有睡眠数据", "在「记录 → 作息运动」里记，或戴手表睡觉"),
                                 tint: Theme.sleep, unit: "小时", label: { String(format: "%.1f 小时", $0.value) }, scrollX: $scrollX)
                    }
                    card("力量训练", "本周 \(store.strength(lastDays(7))) / \(Int(store.data.profile.strengthGoal ?? 2)) 次") {
                        BarChart(bars: strength, ax: ax, goal: nil, empty: ("还没有力量训练", "手表记的力量训练会自动算，也可以在「记录 → 作息运动」里手动加"),
                                 tint: Theme.accent, unit: "次", label: { "\(Int($0.value)) 次" }, scrollX: $scrollX)
                    }
                    card("蛋白质", "今天 \(fmt0(store.protein(today))) / \(fmt0(store.proteinGoalGrams)) g") {
                        BarChart(bars: protein, ax: ax, goal: store.proteinGoalGrams, empty: ("还没有蛋白质数据", "从食物库或拍照记的饮食会自动加总"),
                                 tint: Theme.brand7, unit: "g", label: { "\(fmt0($0.value)) g" }, scrollX: $scrollX)
                    }
                    card("步数", store.steps(today).map { "今天 \(fmt0($0)) 步" + (avg7(steps.filter { past.contains($0.date) }).map { " · 7 日均 \(fmt0($0)) 步" } ?? "") }) {
                        BarChart(bars: steps, ax: ax, goal: nil, empty: health.noData ? ("没有步数数据", "去设置打开健康权限") : ("没有步数数据", "授权健康 App 后自动同步"),
                                 tint: Theme.accent, unit: "步", label: { "\(fmt0($0.value)) 步" }, scrollX: $scrollX)
                    }
                    NavigationLink { BodyListView() } label: {
                        Card(v: 4) { CardRow(title: "全部身体数据", icon: "list.bullet.rectangle.fill", tint: Theme.accent, action: {}).allowsHitTesting(false) }
                    }.buttonStyle(.plain)
                }.padding(16)
            }
            .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "scrollBottom") ? .bottom : .top)  // 截图用：-scrollBottom YES
            .background(Theme.page)
            .toolbar(.hidden, for: .navigationBar).statusBarCover()
            .refreshable { await health.refresh() }
        }
    }

    // 体重副标题：有方案时比计划（今天按计划应到的体重），没有方案时看近 7 天
    func weightLine(_ t: (points: [(date: String, weight: Double, trend: Double)], weekly: Double?), _ plan: Plan?) -> String? {
        guard let p = t.points.last else { return nil }
        let cur = String(format: "当前 %.1f kg", p.trend)
        if let plan, plan.ended == nil { return cur + " · 较计划 " + signed(p.trend - store.planned(plan, on: dayKey())) + " kg" }
        return cur + (t.weekly.map { " · 近 7 天 " + signed($0, "%.2f") + " kg" } ?? "")
    }

    func avg7(_ bars: [Bar]) -> Double? { let b = bars.suffix(7); return b.isEmpty ? nil : b.map(\.value).reduce(0, +) / Double(b.count) }

    // MARK: 图表

    // pts = 当前时间段里的点；total = 全部体重记录天数（解锁看的是总数，选了方案也不会被重新锁住）
    @ViewBuilder func weightChart(_ pts: [(date: String, weight: Double, trend: Double)], _ total: Int, _ target: Double, _ ax: Axis, _ plan: Plan?) -> some View {
        if total < 3 {
            empty("记录 3 天解锁趋势", "已记录 \(total) 天")
        } else {
            let sel = selW.flatMap { s in pts.min { abs(ISO.date($0.date)!.timeIntervalSince(s)) < abs(ISO.date($1.date)!.timeIntervalSince(s)) } }
            Chart {
                ForEach(pts, id: \.date) { p in
                    PointMark(x: .value("日期", ISO.date(p.date)!, unit: .day), y: .value("体重", p.weight)).foregroundStyle(Theme.ink3.opacity(0.45)).symbolSize(18)
                    LineMark(x: .value("日期", ISO.date(p.date)!, unit: .day), y: .value("趋势", p.trend), series: .value("线", "趋势")).foregroundStyle(Theme.accent)
                        .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5))
                }
                if let plan {
                    ForEach([(ISO.date(plan.start)!, plan.startWeight), (ISO.date(plan.end)!, plan.target)], id: \.0) { p in
                        LineMark(x: .value("日期", p.0, unit: .day), y: .value("计划", p.1), series: .value("线", "计划")).foregroundStyle(Theme.warn)
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    }
                } else {
                    RuleMark(y: .value("目标", target)).foregroundStyle(Theme.warn).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                }
                if ax.today { RuleMark(x: .value("今天", Calendar.current.startOfDay(for: .now), unit: .day)).foregroundStyle(Theme.ink3).lineStyle(StrokeStyle(lineWidth: 1)) }
                if let s = sel {
                    RuleMark(x: .value("选中", ISO.date(s.date)!, unit: .day)).foregroundStyle(Theme.ink3)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            callout(s.date, [String(format: "读数 %.1f kg", s.weight), String(format: "趋势 %.1f kg", s.trend)] + (plan.map { [String(format: "计划 %.1f kg", store.planned($0, on: s.date))] } ?? []))
                        }
                }
            }
            .timeAxis(ax, $scrollX)
            .chartYScale(domain: .automatic(includesZero: false)).yUnit("kg")
            .chartXSelection(value: $selW)
            .frame(height: 210)
            // 图例在图下左边；和计划比的结论只在右上「较计划」写一次
            HStack(spacing: 12) {
                legendLine(Theme.accent, "趋势"); legendLine(Theme.warn, plan == nil ? "目标" : "计划", dash: true)
                HStack(spacing: 4) { Circle().fill(Theme.ink3).frame(width: 6, height: 6); Text("每日读数") }
                Spacer()
            }.font(.caption2).foregroundStyle(Theme.ink7).padding(.top, 8)
        }
    }

    func legendLine(_ c: Color, _ t: String, dash: Bool = false) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(c, style: StrokeStyle(lineWidth: dash ? 1.2 : 2.5, dash: dash ? [4, 3] : [])).frame(width: 14, height: 2)
            Text(t)
        }
    }

    @ViewBuilder func girthChart(_ pts: [(date: String, cm: Double)], _ ax: Axis, _ name: String) -> some View {
        if pts.isEmpty {
            empty("还没有\(name)记录", "在「记录 → 身体」里点\(name)那一行")
        } else {
            let sel = selGirth.flatMap { s in pts.min { abs(ISO.date($0.date)!.timeIntervalSince(s)) < abs(ISO.date($1.date)!.timeIntervalSince(s)) } }
            Chart {
                ForEach(pts, id: \.date) { p in
                    LineMark(x: .value("日期", ISO.date(p.date)!, unit: .day), y: .value(name, p.cm)).foregroundStyle(Theme.accent).interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5))
                    PointMark(x: .value("日期", ISO.date(p.date)!, unit: .day), y: .value(name, p.cm)).foregroundStyle(Theme.accent).symbolSize(24)
                }
                if ax.today { RuleMark(x: .value("今天", Calendar.current.startOfDay(for: .now), unit: .day)).foregroundStyle(Theme.ink3).lineStyle(StrokeStyle(lineWidth: 1)) }
                if let s = sel {
                    RuleMark(x: .value("选中", ISO.date(s.date)!, unit: .day)).foregroundStyle(Theme.ink3)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { callout(s.date, ["\(name) \(fmt1(s.cm)) cm"]) }
                }
            }
            .timeAxis(ax, $scrollX)
            .chartYScale(domain: .automatic(includesZero: false)).yUnit("cm")
            .chartXSelection(value: $selGirth)
            .frame(height: 160).padding(.top, 10)
        }
    }

    // MARK: 小组件：卡内标题 16 半粗墨色，副信息 13 墨色 7（放不下时缩小，不截断）

    func card<C: View>(_ title: String, _ headline: String?, @ViewBuilder _ content: () -> C) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.cardTitle).foregroundStyle(Theme.ink).fixedSize()
                Spacer()
                if let headline { Text(headline).font(.footnote).foregroundStyle(Theme.ink7).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7) }
            }.padding(.bottom, 10)
            content()
        }
    }
}

// 纵轴刻度带单位（54 kg、1,500 kcal）
extension View {
    func yUnit(_ unit: String) -> some View {
        chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(d.formatted()) \(unit)") } } } }
    }
}

// 横轴：选了方案时固定铺满方案周期（today = 进行中，画今天竖线）；全部记录时一屏 30 天可滑
struct Axis { let from: Date, to: Date, scroll: Bool, today: Bool }

extension View {
    @ViewBuilder func timeAxis(_ ax: Axis, _ x: Binding<Date>) -> some View {
        if ax.scroll {
            chartXScale(domain: ax.from...max(ax.to, ax.from.addingTimeInterval(VISIBLE)), range: .plotDimension(endPadding: 12))
                .chartScrollableAxes(.horizontal).chartXVisibleDomain(length: VISIBLE).chartScrollPosition(x: x)
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine().foregroundStyle(Theme.page); AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
        } else {
            chartXScale(domain: ax.from...max(ax.to, ax.from.addingTimeInterval(7 * 86400)), range: .plotDimension(endPadding: 8))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine().foregroundStyle(Theme.page); AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
        }
    }
}

func empty(_ title: String, _ sub: String) -> some View {
    VStack(spacing: 6) {
        Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(Theme.ink3)
        Text(title).font(.subheadline).foregroundStyle(Theme.ink7)
        Text(sub).font(.caption).foregroundStyle(Theme.ink7).multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity, minHeight: 110)
}

func callout(_ date: String, _ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text("\(monthDay(ISO.date(date)!)) \(weekday(ISO.date(date)!))").font(.caption2.bold()).foregroundStyle(Theme.ink)
        ForEach(lines, id: \.self) { Text($0).font(.caption2).foregroundStyle(Theme.ink).monospacedDigit() }
    }
    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.white).shadow(color: .black.opacity(0.12), radius: 3))
}

struct Bar: Identifiable { var id: String { date }; let date: String; let value: Double }

// 每日柱状图（喝水 / 睡眠 / 力量训练 / 蛋白质 / 步数共用）：目标是橙色虚线；按住拖动看当天
struct BarChart: View {
    let bars: [Bar], ax: Axis, goal: Double?, empty: (String, String)
    let tint: Color, unit: String, label: (Bar) -> String
    @Binding var scrollX: Date
    @State var sel: Date?

    var body: some View {
        if bars.isEmpty {
            BooheeLite.empty(empty.0, empty.1)
        } else {
            let s = sel.flatMap { d in bars.first { Calendar.current.isDate(ISO.date($0.date)!, inSameDayAs: d) } }
            Chart {
                ForEach(bars) { b in
                    BarMark(x: .value("日期", ISO.date(b.date)!, unit: .day), y: .value("数值", b.value)).foregroundStyle(tint).cornerRadius(3)
                }
                if let goal { RuleMark(y: .value("目标", goal)).foregroundStyle(Theme.warn).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3])) }
                if ax.today { RuleMark(x: .value("今天", Calendar.current.startOfDay(for: .now), unit: .day)).foregroundStyle(Theme.ink3).lineStyle(StrokeStyle(lineWidth: 1)) }
                if let s {
                    RuleMark(x: .value("选中", ISO.date(s.date)!, unit: .day)).foregroundStyle(Theme.ink3.opacity(0.6))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { callout(s.date, [label(s)]) }
                }
            }
            .timeAxis(ax, $scrollX).yUnit(unit)
            .chartXSelection(value: $sel)
            .frame(height: 170)
        }
    }
}

// 热量缺口：柱子总高 = 当天总消耗；灰 = 摄入，绿 = 缺口，橙 = 吃超的部分；浅色 = 今天还没过完，或那天没记饮食、按日记估算
struct BalanceChart: View {
    let rows: [Store.DayBalance], ax: Axis
    @Binding var scrollX: Date
    @State var sel: Date?

    var body: some View {
        let today = dayKey()
        if rows.isEmpty {
            BooheeLite.empty("还没有可算缺口的日子", "记一天完整的饮食就能算出来")
        } else {
            let s = sel.flatMap { d in rows.first { Calendar.current.isDate(ISO.date($0.date)!, inSameDayAs: d) } }
            Chart {
                ForEach(rows) { r in
                    let d = ISO.date(r.date)!, fade = r.estimated || r.date == today
                    BarMark(x: .value("日期", d, unit: .day), yStart: .value("kcal", 0), yEnd: .value("kcal", min(r.burn, r.intake)))
                        .foregroundStyle(Theme.ink3.opacity(fade ? 0.35 : 0.7))
                    if r.burn >= r.intake {
                        BarMark(x: .value("日期", d, unit: .day), yStart: .value("kcal", r.intake), yEnd: .value("kcal", r.burn)).foregroundStyle(Theme.accent.opacity(fade ? 0.45 : 1))
                    } else {
                        BarMark(x: .value("日期", d, unit: .day), yStart: .value("kcal", r.burn), yEnd: .value("kcal", r.intake)).foregroundStyle(Theme.warn.opacity(fade ? 0.45 : 1))
                    }
                }
                if ax.today { RuleMark(x: .value("今天", Calendar.current.startOfDay(for: .now), unit: .day)).foregroundStyle(Theme.ink3).lineStyle(StrokeStyle(lineWidth: 1)) }
                if let s {
                    RuleMark(x: .value("选中", ISO.date(s.date)!, unit: .day)).foregroundStyle(Theme.ink3.opacity(0.6))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            callout(s.date, ["消耗 \(fmt0(s.burn)) · 摄入 \(fmt0(s.intake))", "\(s.burn >= s.intake ? "缺口" : "吃超") \(fmt0(abs(s.burn - s.intake))) kcal\(s.estimated ? "（日记估算）" : "")"])
                        }
                }
            }
            .timeAxis(ax, $scrollX).yUnit("kcal")
            .chartXSelection(value: $sel)
            .frame(height: 190)
            HStack(spacing: 14) { legend(Theme.ink3, "摄入"); legend(Theme.accent, "缺口"); legend(Theme.warn, "吃超"); Spacer() }.font(.caption2).foregroundStyle(Theme.ink7).padding(.top, 8)
        }
    }

    func legend(_ c: Color, _ t: String) -> some View { HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 8); Text(t) } }
}

import SwiftUI

// MARK: 身体数据：全部记录（趋势页进入）+ 录入（刻度尺，薄荷 BooheeRulerView 的交互，也能切键盘；每个围度固定一种量法）

struct BodyListView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var health: HealthService
    @State var editing: EntryDay?

    var body: some View {
        let local = Dictionary(store.data.body.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let dates = Array(Set(local.keys).union(health.weights.keys).sorted(by: >).prefix(365))
        List {
            if dates.isEmpty { Text("还没有身体数据 · 点右上角 + 记一笔").foregroundStyle(Theme.ink7) }
            Section {
                ForEach(dates, id: \.self) { d in
                    if local[d] == nil { row(d, nil) }  // 健康 App 来源只读
                    else { Button { editing = EntryDay(date: d) } label: { row(d, local[d]) }.foregroundStyle(Theme.ink) }
                }.onDelete { idx in let ds = idx.map { dates[$0] }; store.data.body.removeAll { ds.contains($0.date) }; store.save() }
            } footer: { if dates.contains(where: { local[$0] == nil }) { Text("标「健康」的体重来自健康 App，只读；要删请在健康 App 里删除") } }
        }
        .navigationTitle("全部身体数据").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { editing = EntryDay(date: dayKey()) } label: { Image(systemName: "plus") }.accessibilityLabel("记一笔") } }
        .sheet(item: $editing) { BodyEntrySheet(date: ISO.date($0.date) ?? .now) }
    }

    // 每天列出记过的所有维度；点开能看全七个围度并修改。标「健康」的是健康 App 里的体重，要在健康 App 里删
    func row(_ d: String, _ b: BodyEntry?) -> some View {
        let w = b?.weight ?? health.weights[d]
        let extra = (GIRTHS.compactMap { g in b?[keyPath: g.key].map { "\(g.short) \(fmt1($0))" } } + [b?.bodyfat.map { "脂 \(fmt1($0))%" }].compactMap { $0 }).joined(separator: " · ")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d).font(.subheadline)
                if !extra.isEmpty { Text(extra).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let w { Text(String(format: "%.1f kg", w)).monospacedDigit() }
            if b == nil { Tag("健康") }
        }.deleteDisabled(b == nil)
    }
}

struct EntryDay: Identifiable { let date: String; var id: String { date } }

func fmt1(_ x: Double) -> String { x == x.rounded() ? "\(Int(x))" : String(format: "%.1f", x) }

struct WeightProgress: View {
    let start: (date: String, weight: Double)?, current: (date: String, weight: Double)?, target: Double
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                col("起始", start?.weight, start.map { String($0.date.suffix(5)) })
                col("当前", current?.weight, current.map { String($0.date.suffix(5)) }, big: true)
                col("目标", target, nil)
            }
            if let s = start?.weight, let c = current?.weight, abs(s - target) > 0.05 {
                let lose = s > target, moved = lose ? s - c : c - s, left = lose ? c - target : target - c
                ProgressView(value: min(max(moved / abs(s - target), 0), 1)).tint(Theme.accent)
                Text(left <= 0 ? String(format: "恭喜！完成目标，共%@ %.1f kg", lose ? "减" : "增", abs(moved))
                     : moved < 0 ? String(format: "比起始%@了 %.1f kg · 还差 %.1f kg", lose ? "重" : "轻", -moved, left)
                     : String(format: "已%@ %.1f kg · 还差 %.1f kg", lose ? "减" : "增", moved, left))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    func col(_ t: String, _ v: Double?, _ sub: String?, big: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v.map { String(format: "%.1f", $0) } ?? "—").font(.system(big ? .title : .title3, design: .rounded, weight: .bold)).monospacedDigit()
                .foregroundStyle(big ? Theme.accent : Color.primary)
            Text(sub ?? "kg").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct BodyEntrySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var date: Date
    @State var weight = 60.0
    @State var ready = false
    @State var keyboard = false
    @State var text = ""
    @State var girth: [String: String] = [:]  // 部位名 → 输入框文字
    @State var fat = ""

    init(date: Date = .now) { _date = State(initialValue: date) }

    var valid: Bool { (25...200).contains(weight) }  // 薄荷的输入范围：25–200 公斤

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", weight)).font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit().contentTransition(.numericText(value: weight))
                            Text("kg").font(.headline)
                        }.foregroundStyle(valid ? Theme.accent : Theme.warn)
                        if keyboard {
                            TextField("输入体重", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.center).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                                .onChange(of: text) { _, t in if let v = Double(t) { weight = v } }
                        } else if ready {
                            RulerPicker(value: $weight, range: 25...200, step: 0.1)
                        }
                        Button(keyboard ? "用刻度尺" : "键盘输入") { text = String(format: "%.1f", weight); keyboard.toggle() }.font(.footnote).buttonStyle(.borderless)
                        if !valid { Text("体重正常范围 25–200 kg").font(.caption).foregroundStyle(.orange) }
                    }.frame(maxWidth: .infinity)
                } footer: { Text(WEIGH_RULE) }
                Section {
                    ForEach(GIRTHS, id: \.name) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            field(g.name, "cm", Binding(get: { girth[g.name] ?? "" }, set: { girth[g.name] = $0 }))
                            Text(g.how).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        field("体脂率", "%", $fat)
                        Text("用同一台体脂秤，在同一个时间段测").font(.caption2).foregroundStyle(.secondary)
                    }
                } header: { Text("围度和体脂（选填）") } footer: { Text(MEASURE_RULE) }
                Section { DatePicker("日期", selection: $date, in: ...Date.now, displayedComponents: .date) } footer: { Text("体重会写回健康 App。同一天再记会覆盖这一天。") }
            }
            .navigationTitle("记身体数据").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(store.data.body.contains { $0.date == dayKey(date) } ? "更新" : "保存") { save() }.disabled(!valid) }
            }
            .onAppear { if !ready { weight = ((store.latestWeight(dayKey(date))) * 10).rounded() / 10; prefill(); ready = true } }
            .onChange(of: date) { _, _ in prefill() }
        }
    }

    func field(_ name: String, _ unit: String, _ v: Binding<String>) -> some View {
        HStack { Text(name); TextField("—", text: v).keyboardType(.decimalPad).multilineTextAlignment(.trailing); Text(unit).foregroundStyle(.secondary) }
    }

    // 同一天已有记录就带出来，避免只改体重时把当天的围度 / 体脂覆盖掉
    func prefill() {
        let b = store.data.body.first { $0.date == dayKey(date) }
        if let w = b?.weight { weight = w }
        for g in GIRTHS { girth[g.name] = b?[keyPath: g.key].map(fmt1) ?? "" }
        fat = b?.bodyfat.map(fmt1) ?? ""
    }

    func save() {
        var b = BodyEntry(date: dayKey(date), weight: (weight * 10).rounded() / 10, bodyfat: Double(fat))
        for g in GIRTHS { b[keyPath: g.key] = Double(girth[g.name] ?? "") }
        store.addBody(b)
        dismiss()
    }
}

// 刻度尺：0.1 一格，整数长刻度带数字，中间的竖线是当前值；滑动有轻触反馈
struct RulerPicker: View {
    @Binding var value: Double
    let range: ClosedRange<Double>, step: Double
    @State private var idx: Int?
    private let gap: CGFloat = 10

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
        _value = value; self.range = range; self.step = step
        _idx = State(initialValue: Int(((value.wrappedValue - range.lowerBound) / step).rounded()))
    }

    var body: some View {
        let n = Int(((range.upperBound - range.lowerBound) / step).rounded())
        GeometryReader { g in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(0...n, id: \.self) { i in
                        VStack(spacing: 6) {
                            Capsule().fill(i % 10 == 0 ? Color.primary.opacity(0.55) : Color.secondary.opacity(0.45))
                                .frame(width: i % 10 == 0 ? 2 : 1, height: i % 10 == 0 ? 30 : (i % 5 == 0 ? 22 : 14))
                            if i % 10 == 0 { Text("\(Int(range.lowerBound + Double(i) * step))").font(.caption2).foregroundStyle(.secondary).fixedSize() }
                        }.frame(width: gap, height: 60, alignment: .top)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $idx)  // 不带 anchor：刻度对齐 safe area 左缘，也就是正中间（带 .center 会整体偏半个尺宽）
            .safeAreaPadding(.horizontal, (g.size.width - gap) / 2)
            .overlay(alignment: .top) { Capsule().fill(Theme.accent).frame(width: 4, height: 40).offset(y: -4) }
        }
        .frame(height: 60)
        .onChange(of: idx) { _, i in if let i { value = range.lowerBound + Double(i) * step } }
        .onChange(of: value) { _, v in let i = Int(((v - range.lowerBound) / step).rounded()); if i != idx { idx = i } }
        .sensoryFeedback(.selection, trigger: idx)
    }
}

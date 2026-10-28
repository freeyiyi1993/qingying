import Foundation
import SwiftUI

// 口径与 boohee_lite/energy.py 一致：设备活动大卡已含运动，不叠加；无设备 = 0.2×BMR + 手动运动。

struct Food: Codable, Hashable, Identifiable { var name: String; var aliases: String; var kcal: Double; var carb: Double; var protein: Double; var fat: Double; var oily: Bool
    var id: String { name } }

struct FoodLog: Codable, Identifiable, Hashable {
    var id = UUID(); var date: String; var meal: String; var name: String; var grams: Double
    var kcal: Double; var carb: Double = 0; var protein: Double = 0; var fat: Double = 0; var source: String
}

struct BodyEntry: Codable, Identifiable, Hashable {
    var id = UUID(); var date: String; var weight: Double?; var waist: Double?; var hip: Double?; var bodyfat: Double?
    var chest: Double?; var belly: Double?; var arm: Double?; var thigh: Double?; var calf: Double?  // 后加的一律 Optional，旧数据缺 key 照样解码
}

// 围度：薄荷的六个部位（胸、腰、臀、手臂、大腿、小腿）+ 下腹围（内裤边那一圈）；每个部位固定一种量法，保证前后口径一致
let GIRTHS: [(name: String, short: String, key: WritableKeyPath<BodyEntry, Double?>, how: String)] = [
    ("胸围", "胸", \.chest, "软尺过乳头水平绕一圈，保持水平，正常呼吸时读数"),
    ("腰围", "腰", \.waist, "肚脐上方最细处，自然站立不收腹，呼气末读数"),
    ("下腹围", "下腹", \.belly, "内裤边那一圈（约肚脐下 5 cm），呼气末读数"),
    ("臀围", "臀", \.hip, "臀部最突出处水平绕一圈，双脚并拢"),
    ("臂围", "臂", \.arm, "上臂最粗处（肩到肘中点），手臂自然下垂放松，固定量同一侧"),
    ("大腿围", "大腿", \.thigh, "臀横纹下方大腿最粗处，双脚与肩同宽，固定量同一侧"),
    ("小腿围", "小腿", \.calf, "小腿最粗处，站立、重心均匀，固定量同一侧")]
let MEASURE_RULE = "统一口径：早上起床、如厕后、空腹测；站立放松，软尺贴皮肤但不勒紧，每次用同一根软尺。"
let WEIGH_RULE = "统一口径：早上起床、如厕后、空腹称，穿同样的衣服，用同一台秤。"

struct ManualWorkout: Codable, Identifiable, Hashable {
    var id = UUID(); var date: String; var type: String; var minutes: Double; var met: Double; var kcal: Double
}

struct Profile: Codable {
    var sex = "male"; var birthYear = 1993; var heightCm = 175.0; var targetWeight = 65.0
    var deficitGoal = 300.0; var eatBack = 0.6; var photoServer = "http://192.168.1.10:8765"
    var aiProvider: String?; var aiModel: String?; var aiBaseURL: String?  // AI 识别；API Key 存钥匙串，不进这个文件
    var waterGoal: Double?; var sleepGoal: Double?
    var strengthGoal: Double?; var proteinGoal: Double?  // 基础代谢保障：力量训练每周次数、蛋白质每公斤体重克数
}

// 日记里手估的当天热量缺口：没记饮食的日子用它画趋势
struct DayEstimate: Codable, Identifiable, Hashable { var id = UUID(); var date: String; var deficit: Double }
// 手动记的睡眠（按醒来那天归日）：有手动记录时以它为准，否则用健康 App 的
struct SleepLog: Codable, Identifiable, Hashable { var id = UUID(); var date: String; var hours: Double; var bed: String?; var wake: String? }
// 手动改的步数：有手动记录时以它为准，「恢复自动」删掉这一条回到健康 App 的
struct StepLog: Codable, Identifiable, Hashable { var id = UUID(); var date: String; var steps: Double }
struct WaterLog: Codable, Identifiable, Hashable { var id = UUID(); var date: String; var ml: Double; var hk: UUID? }  // hk：写进健康 App 的那条样本，撤销时一起删
// 体重管理方案：起点到目标按天线性画计划线；结束或调整时归档（ended = 结束那天），趋势页可以按方案看
struct Plan: Codable, Hashable, Identifiable { var start: String; var startWeight: Double; var target: Double; var end: String; var ended: String?
    var id: String { start + "~" + end }
    // 下拉里用日期范围标识方案：已结束的写实际结束那天，跨年时结束日期才带年份，如 2026.10.27 – 12.18、2026.10.27 – 2027.4.29
    var range: String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy.M.d"
        let e = ended ?? end, s = f.string(from: ISO.date(start)!)
        if e.prefix(4) == start.prefix(4) { f.dateFormat = "M.d" }
        return "\(s) – \(f.string(from: ISO.date(e)!))"
    } }

struct DataFile: Codable {
    var foods: [Food] = []; var logs: [FoodLog] = []; var body: [BodyEntry] = []
    var workouts: [ManualWorkout] = []; var profile = Profile()
    var estimates: [DayEstimate]?; var waters: [WaterLog]?; var plan: Plan?; var plans: [Plan]?; var sleeps: [SleepLog]?; var steps: [StepLog]?  // 后加的一律 Optional；plans = 已结束的方案
}

let MEALS = ["早餐", "午餐", "晚餐", "加餐"]
let INTAKE_FLOOR = ["female": 1200.0, "male": 1500.0]
let DEFICIT_RANGE = 200.0...500.0  // 建议的每日缺口，超出时提醒但不强制
let KCAL_PER_KG = 7700.0  // 减 1 kg 体重约需 7700 kcal 缺口（经验值）

func dayKey(_ d: Date = .now) -> String {
    let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
}
func r10(_ x: Double) -> Int { Int((x / 10).rounded() * 10) }
// 最近 n 天（含今天），从早到晚
func lastDays(_ n: Int) -> [String] { (0..<n).reversed().map { dayKey(Calendar.current.date(byAdding: .day, value: -$0, to: .now)!) } }
// 两个日期之间（含两端）的每一天
func daysBetween(_ a: String, _ b: String) -> [String] {
    guard let s = ISO.date(a), let e = ISO.date(b), s <= e else { return [] }
    let n = Calendar.current.dateComponents([.day], from: s, to: e).day ?? 0
    return (0...n).map { dayKey(Calendar.current.date(byAdding: .day, value: $0, to: s)!) }
}

// 同 photo.py match_food：先精确匹配名称 / 别名，再取互相包含的里面名字最长的
func findFood(_ name: String, in foods: [Food]) -> Food? {
    guard !name.isEmpty else { return nil }
    let alias = { (f: Food) in f.aliases.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
    return foods.first { $0.name == name || alias($0).contains(name) }
        ?? foods.filter { $0.name.contains(name) || name.contains($0.name) || alias($0).contains { $0.contains(name) || name.contains($0) } }
            .max { $0.name.count < $1.name.count }
}

@MainActor
final class Store: ObservableObject {
    @Published var data = DataFile()
    @Published var tab = UserDefaults.standard.string(forKey: "tab").flatMap(Int.init) ?? 2  // 启动即记录；别的页要跳「我的」改设置时也用它
    @Published var cloudChoice: DataFile?  // 登录时云端已有数据：等用户选用云端还是本机的资料和方案
    let health = HealthService()
    let cloud = Cloud()
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("boohee.json")

    init() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(DataFile.self, from: d) { data = f }
        let custom = Set(data.foods.map(\.name))
        data.foods += Self.seed().filter { !custom.contains($0.name) }
        health.onRefresh = { [weak self] in self?.applyHealthProfile() }
    }

    // 健康 App 有身高 / 性别 / 生日时以它为准，覆盖默认值（175cm / 1993 / 男）。
    func applyHealthProfile() {
        if let h = health.heightCm { data.profile.heightCm = h.rounded() }
        if let s = health.sex { data.profile.sex = s }
        if let y = health.birthYear { data.profile.birthYear = y }
        save()
    }

    static func seed() -> [Food] { (try? JSONDecoder().decode([Food].self, from: Data(contentsOf: Bundle.main.url(forResource: "foods", withExtension: "json")!))) ?? [] }

    func save() { try? JSONEncoder().encode(data).write(to: url, options: .atomic) }

    // 本机没有任何记录：记录页顶部提示「以前用过？登录恢复记录」
    var fresh: Bool { data.logs.isEmpty && data.body.isEmpty && data.workouts.isEmpty && data.plan == nil && (data.plans ?? []).isEmpty }
    var recordCount: Int {
        data.logs.count + data.body.count + data.workouts.count + (data.estimates ?? []).count + (data.waters ?? []).count + (data.sleeps ?? []).count
            + (data.steps ?? []).count + (data.plans ?? []).count + (data.plan == nil ? 0 : 1)
    }

    // 登录：云端没有数据就把本机的传上去；有数据先问用哪边的资料和方案（换新手机时本机是默认资料，不能直接盖掉云端）
    func signIn() async {
        guard await cloud.signInWithGoogle() else { return }
        do { if let remote = try await cloud.download() { cloudChoice = remote } else { await cloud.upload(data) } }
        catch { cloud.status = "同步失败：\(error.localizedDescription)" }
    }
    // 记录两边按 id 取并集；useRemote = 资料和方案用云端的
    func adopt(_ remote: DataFile, useRemote: Bool) async {
        let before = recordCount
        data = useRemote ? mergeData(remote, data) : mergeData(data, remote)
        try? JSONEncoder().encode(data).write(to: url, options: .atomic)
        await cloud.upload(data)
        cloud.status = "已合并 \(max(recordCount - before, 0)) 条记录"
    }

    // 删除所有数据：先删云端 users/{uid} 并退出登录，再清空本机（食物库恢复成内置的）
    func deleteAll() async -> Bool {
        if cloud.signedIn {
            do { try await cloud.deleteRemote() } catch { cloud.status = "云端删除失败：\(error.localizedDescription)"; return false }
            cloud.signOut()
        }
        data = DataFile(); data.foods = Self.seed(); save()
        cloud.status = "已删除本机和云端的所有数据"
        return true
    }

    // 凌晨后台任务和「立即同步」：以本机为准整份上传，不拉云端合并，本机删掉的记录不会被带回来；云端数据只在登录时合并进来
    func syncNow() async {
        guard cloud.signedIn, !fresh else { return }  // 本机一条记录都没有时不传，免得盖掉云端备份
        cloud.busy = true
        defer { cloud.busy = false }
        await cloud.upload(data)
    }

    func searchFoods(_ q: String) -> [Food] {
        guard !q.isEmpty else { return data.foods }
        return data.foods.filter { $0.name.contains(q) || $0.aliases.contains(q) }
    }
    func matchFood(_ name: String) -> Food? { findFood(name, in: data.foods) }

    func addLog(_ l: FoodLog) { data.logs.append(l); save(); Task { await health.writeIntake(kcal: l.kcal, date: l.date) } }
    // 复制记录（薄荷「复制记录」）：整份复制到目标日期和餐次
    func copyLogs(_ logs: [FoodLog], to day: String, meal: String) {
        for l in logs { addLog(FoodLog(date: day, meal: meal, name: l.name, grams: l.grams, kcal: l.kcal, carb: l.carb, protein: l.protein, fat: l.fat, source: l.source)) }
    }
    func addWater(_ ml: Double, date: String) {
        let w = WaterLog(date: date, ml: ml)
        data.waters = (data.waters ?? []) + [w]; save()
        Task {
            guard let hk = await health.writeWater(ml, date: date), let i = data.waters?.firstIndex(where: { $0.id == w.id }) else { return }
            data.waters?[i].hk = hk; save()
        }
    }
    func removeWater(_ id: UUID) {
        guard let i = data.waters?.firstIndex(where: { $0.id == id }) else { return }
        let hk = data.waters?.remove(at: i).hk; save()
        if let hk { Task { await health.deleteWater(hk) } }
    }
    // 喝水 = 本 App 记的 + 健康 App 里其他来源的（本 App 写进健康 App 的不重复算）
    func water(_ day: String) -> Double { (data.waters ?? []).filter { $0.date == day }.reduce(0) { $0 + $1.ml } + (health.water[day] ?? 0) }
    func estimate(_ day: String) -> Double? { data.estimates?.first { $0.date == day }?.deficit }
    // 步数：手动改过的为准，否则用健康 App 的
    func steps(_ day: String) -> Double? { data.steps?.first { $0.date == day }?.steps ?? health.steps[day] }
    func setSteps(_ day: String, _ v: Double?) {
        var s = data.steps ?? []
        s.removeAll { $0.date == day }
        if let v { s.append(StepLog(date: day, steps: v)) }
        data.steps = s; save()
    }
    // 蛋白质：当天饮食记录里的蛋白质克数加总；力量训练：手表的力量类体能训练 + 手动记的「力量训练」，按次数
    func protein(_ day: String) -> Double { data.logs.filter { $0.date == day }.reduce(0) { $0 + $1.protein } }
    func strength(_ days: [String]) -> Int {
        let ds = Set(days)
        return health.workouts.filter { ds.contains($0.date) && $0.type.contains("力量") }.count + data.workouts.filter { ds.contains($0.date) && $0.type.contains("力量") }.count
    }
    var proteinGoalGrams: Double { ((data.profile.proteinGoal ?? 1.2) * (weights().last?.weight ?? 60) / 5).rounded() * 5 }
    func sleep(_ day: String) -> Double? { data.sleeps?.first { $0.date == day }?.hours ?? health.sleep[day] }
    func setSleep(_ day: String, hours: Double?, bed: String? = nil, wake: String? = nil) {
        var s = data.sleeps ?? []
        s.removeAll { $0.date == day }
        if let hours { s.append(SleepLog(date: day, hours: hours, bed: bed, wake: wake)) }
        data.sleeps = s; save()
    }

    func addBody(_ b: BodyEntry, writeWeight: Bool = true) {
        data.body.removeAll { $0.date == b.date }; data.body.append(b); save()
        if writeWeight, let w = b.weight { Task { await health.writeWeight(w, date: b.date) } }
    }
    // 只改某一天的某一个维度，其余维度保留；只有改体重才写回健康 App
    func setBody(_ day: String, _ key: WritableKeyPath<BodyEntry, Double?>, _ v: Double?) {
        var b = data.body.first { $0.date == day } ?? BodyEntry(date: day)
        b[keyPath: key] = v
        addBody(b, writeWeight: key == \BodyEntry.weight)
    }

    // 开始新方案：旧方案归档；结束方案同理
    func startPlan(_ p: Plan) { endPlan(); data.plan = p; save() }
    func endPlan() {
        guard var old = data.plan else { return }
        old.ended = dayKey(); data.plans = (data.plans ?? []) + [old]; data.plan = nil; save()
    }
    // 删除已结束的方案：只删方案本身，期间的记录保留
    func deletePlan(_ id: String) { data.plans?.removeAll { $0.id == id }; save() }
    // 方案下拉的选项：当前的在前，已结束的从近到远；当天开始当天就调整 / 结束掉的不列（没有数据，日期范围也会和后面的方案重复）
    var allPlans: [Plan] { (data.plan.map { [$0] } ?? []) + (data.plans ?? []).filter { $0.ended != $0.start }.reversed() }

    // 合并本地记录与健康 App 体重；同日本地优先。
    func weights() -> [(date: String, weight: Double)] {
        var m: [String: Double] = [:]
        for (d, w) in health.weights { m[d] = w }
        for b in data.body { if let w = b.weight { m[b.date] = w } }
        return m.keys.sorted().map { ($0, m[$0]!) }
    }
    func latestWeight(_ day: String) -> Double { weights().last { $0.date <= day }?.weight ?? 60 }

    func trend() -> (points: [(date: String, weight: Double, trend: Double)], weekly: Double?) {
        var out: [(String, Double, Double)] = []
        for p in weights() { out.append((p.date, p.weight, out.isEmpty ? p.weight : 0.25 * p.weight + 0.75 * out.last!.2)) }
        guard let last = out.last.flatMap({ ISO.date($0.0) }) else { return (out, nil) }
        func age(_ s: String) -> Int { Calendar.current.dateComponents([.day], from: ISO.date(s)!, to: last).day! }
        let a = out.filter { age($0.0) < 7 }.map(\.2), b = out.filter { (7..<14).contains(age($0.0)) }.map(\.2)
        let wk = (a.isEmpty || b.isEmpty) ? nil : a.reduce(0, +) / Double(a.count) - b.reduce(0, +) / Double(b.count)
        return (out, wk)
    }

    // raw = 按公式算的预算（可能低于摄入下限）；daily = 日常活动（活动消耗里扣掉专门运动的部分），exercise = 专门运动
    struct Summary { var bmr, active, totalBurn, intake, budget, remaining, goal, raw, floor, eatBack, daily, exercise: Double; var basis: String; var device, bmrFromHealth: Bool; var alerts: [String] }

    func formulaBMR(_ day: String, weight: Double? = nil) -> Double {
        let p = data.profile, w = weight ?? latestWeight(day), age = Double(Int(day.prefix(4))! - p.birthYear)
        return 10 * w + 6.25 * p.heightCm - 5 * age + (p.sex == "male" ? 5 : -161)
    }
    // 过去的日子健康 App 有完整的静息能量就用它；今天还没过完，用公式算全天
    func bmr(_ day: String, weight: Double? = nil) -> Double { healthBMR(day) ?? formulaBMR(day, weight: weight) }
    func healthBMR(_ day: String) -> Double? {
        guard day < dayKey(), let b = health.basalKcal[day], b > 0.6 * formulaBMR(day) else { return nil }
        return b
    }

    struct DayEnergy: Identifiable { var id: String { date }; let date: String; let burn: Double; let intake: Double; let device: Bool }

    // 每日消耗，口径同 summary；整天没有任何数据的日子不出图（device=false 即按 0.2×BMR 估算）
    func energy(_ dates: [String]) -> [DayEnergy] {
        var intake: [String: Double] = [:], manual: [String: Double] = [:]
        for l in data.logs { intake[l.date, default: 0] += l.kcal }
        for w in data.workouts { manual[w.date, default: 0] += w.kcal }
        let ws = weights()
        return dates.compactMap { d in
            let hk = health.activeKcal[d] ?? 0
            guard hk > 0 || intake[d] != nil || manual[d] != nil else { return nil }
            let b = bmr(d, weight: ws.last { $0.date <= d }?.weight ?? 60)
            return DayEnergy(date: d, burn: b + (hk > 0 ? hk : 0.2 * b + (manual[d] ?? 0)), intake: intake[d] ?? 0, device: hk > 0)
        }
    }

    struct DayBalance: Identifiable { var id: String { date }; let date: String; let burn, intake: Double; let estimated: Bool }

    // 趋势页「每日消耗与热量缺口」：记了饮食的日子 = 消耗 + 摄入；没记饮食但日记里估过缺口的，消耗按无设备口径估、摄入 = 消耗 − 缺口（estimated）
    func balances(_ dates: [String]) -> [DayBalance] {
        let est = Dictionary((data.estimates ?? []).map { ($0.date, $0.deficit) }, uniquingKeysWith: { a, _ in a })
        let e = Dictionary(uniqueKeysWithValues: energy(dates).map { ($0.date, $0) })
        let ws = weights()
        return dates.compactMap { d in
            if let x = e[d], x.intake > 0 { return DayBalance(date: d, burn: x.burn, intake: x.intake, estimated: false) }
            guard let v = est[d] else { return nil }
            let b = bmr(d, weight: ws.last { $0.date <= d }?.weight ?? 60), burn = e[d]?.burn ?? 1.2 * b
            return DayBalance(date: d, burn: burn, intake: max(burn - v, 0), estimated: true)
        }
    }

    func summary(_ day: String) -> Summary {
        let p = data.profile, w = latestWeight(day), bmr = self.bmr(day, weight: w)
        let hk = health.activeKcal[day] ?? 0
        let manual = data.workouts.filter { $0.date == day }
        let device = hk > 0
        let active = device ? hk : 0.2 * bmr + manual.reduce(0) { $0 + $1.kcal }
        let intake = data.logs.filter { $0.date == day }.reduce(0) { $0 + $1.kcal }
        let floor = INTAKE_FLOOR[p.sex] ?? 1200
        let goal = data.plan == nil ? 0 : p.deficitGoal  // 没有进行中的方案就不扣缺口（结束方案后预算回到维持体重）
        let raw = bmr + active * p.eatBack - goal, budget = max(raw, floor)
        // 健康 App 的活动能量已经包含体能训练；把训练那部分拆出来单独算「运动」，剩下的是日常活动
        let workoutKcal = health.workouts.filter { $0.date == day }.reduce(0) { $0 + $1.kcal }, manualKcal = manual.reduce(0) { $0 + $1.kcal }
        let exercise = device ? min(workoutKcal, hk) : manualKcal
        var alerts: [String] = []
        let low = (0..<3).filter { i in
            let d = dayKey(Calendar.current.date(byAdding: .day, value: -i, to: ISO.date(day)!)!)
            let ls = data.logs.filter { $0.date == d }
            return !ls.isEmpty && ls.reduce(0) { $0 + $1.kcal } < floor
        }.count
        if low == 3 { alerts.append("连续 3 天摄入低于 \(Int(floor)) kcal，注意吃够（经验下限，非医嘱）") }
        if let wk = trend().weekly, wk < -0.01 * w { alerts.append(String(format: "近一周趋势体重下降 %.1f kg，超过 1%%，降得太快", -wk)) }
        return Summary(bmr: bmr, active: active, totalBurn: bmr + active, intake: intake, budget: budget,
                       remaining: budget - intake, goal: goal, raw: raw, floor: floor, eatBack: p.eatBack,
                       daily: active - exercise, exercise: exercise,
                       basis: device ? "健康 App 活动大卡（已含运动，不叠加）" : "无设备数据：0.2×BMR + 手动运动",
                       device: device, bmrFromHealth: healthBMR(day) != nil, alerts: alerts)
    }

    // 按计划某天应到的体重（起点到目标按天线性）
    func planned(_ p: Plan, on day: String) -> Double {
        let s = ISO.date(p.start)!, e = ISO.date(p.end)!, d = ISO.date(day)!
        let t = min(max(d.timeIntervalSince(s) / max(e.timeIntervalSince(s), 86400), 0), 1)
        return p.startWeight + (p.target - p.startWeight) * t
    }
}

enum ISO {
    static func date(_ s: String) -> Date? {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s)
    }
}

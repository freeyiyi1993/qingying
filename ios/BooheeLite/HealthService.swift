import Foundation
import HealthKit

struct HKWorkoutItem: Identifiable, Hashable { let id: UUID; let date: String; let type: String; let minutes: Double; let kcal: Double }

@MainActor
final class HealthService: ObservableObject {
    let store = HKHealthStore()
    @Published var activeKcal: [String: Double] = [:]
    @Published var basalKcal: [String: Double] = [:]
    @Published var steps: [String: Double] = [:]
    @Published var water: [String: Double] = [:]  // ml，只含其他来源（本 App 记的在 Store.waters 里，避免重复）
    @Published var sleep: [String: Double] = [:]  // 小时，按醒来那天归日
    @Published var workouts: [HKWorkoutItem] = []
    @Published var weights: [String: Double] = [:]
    @Published var heightCm: Double?
    @Published var sex: String?
    @Published var birthYear: Int?
    @Published var status = "未连接健康 App"
    @Published var detail = ""  // 同步明细：每类读到多少天，点状态行才展开
    @Published var noData = false  // 同步完一条都没读到：多半是没给读取权限
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    @Published var syncing = false
    var onRefresh: (() -> Void)?

    private let active = HKQuantityType(.activeEnergyBurned), basal = HKQuantityType(.basalEnergyBurned)
    private let stepType = HKQuantityType(.stepCount), mass = HKQuantityType(.bodyMass), diet = HKQuantityType(.dietaryEnergyConsumed)
    private let height = HKQuantityType(.height), waterType = HKQuantityType(.dietaryWater), sleepType = HKCategoryType(.sleepAnalysis)

    func authorize() async {
        guard available else { status = "这台设备没有健康 App，消耗按基础代谢估算"; return }
        do {
            // 新增的类型（喝水、睡眠）iOS 会再弹一次授权；已决定过的类型不会再弹
            try await store.requestAuthorization(toShare: [mass, diet, waterType],
                                                 read: [active, basal, stepType, mass, height, waterType, sleepType, .workoutType(),
                                                        HKCharacteristicType(.biologicalSex), HKCharacteristicType(.dateOfBirth)])
            await refresh()
        } catch { status = "授权失败：\(error.localizedDescription)" }
    }

    func refresh(days: Int = 365) async {  // 趋势页「年」要一整年
        syncing = true
        defer { syncing = false }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: .now))!
        activeKcal = await daily(active, .kilocalorie(), start)
        basalKcal = await daily(basal, .kilocalorie(), start)
        steps = await daily(stepType, .count(), start)
        water = await daily(waterType, .literUnit(with: .milli), start, excludeSelf: true)
        sleep = await sleepHours(start)
        weights = await bodyMass(start)
        // 窗口外的最近一次体重也要拿到，否则 BMR 回落到默认 60kg
        if let (d, kg) = await latest(mass, .gramUnit(with: .kilo)), weights[d] == nil { weights[d] = kg }
        heightCm = await latest(height, .meterUnit(with: .centi))?.1
        switch (try? store.biologicalSex())?.biologicalSex { case .male: sex = "male"; case .female: sex = "female"; default: sex = nil }
        birthYear = (try? store.dateOfBirthComponents())?.year
        workouts = await fetchWorkouts(start)
        let t = Date.now.formatted(date: .omitted, time: .shortened)
        noData = [activeKcal, basalKcal, steps, water, sleep, weights].allSatisfy(\.isEmpty) && workouts.isEmpty
        status = noData ? "没有读到健康数据" : "\(t) 已同步"
        detail = "活动 \(activeKcal.count) 天 · 静息 \(basalKcal.count) 天 · 步数 \(steps.count) 天 · 睡眠 \(sleep.count) 晚 · 体重 \(weights.count) 条 · 运动 \(workouts.count) 次"
        onRefresh?()
    }

    private func daily(_ t: HKQuantityType, _ unit: HKUnit, _ start: Date, excludeSelf: Bool = false) async -> [String: Double] {
        var pred: NSPredicate = HKQuery.predicateForSamples(withStart: start, end: nil)
        if excludeSelf {
            pred = NSCompoundPredicate(andPredicateWithSubpredicates: [pred, NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))])
        }
        let q = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: t, predicate: pred),
                                                     options: .cumulativeSum, anchorDate: start,
                                                     intervalComponents: DateComponents(day: 1))
        guard let c = try? await q.result(for: store) else { return [:] }
        var out: [String: Double] = [:]
        c.enumerateStatistics(from: start, to: .now) { s, _ in
            if let v = s.sumQuantity()?.doubleValue(for: unit), v > 0 { out[dayKey(s.startDate)] = v }
        }
        return out
    }

    // 睡眠：只算「睡着」的阶段（不含卧床、清醒），多个来源（手表 / 手机 / 佳明）时间重叠的部分合并后再求和
    private func sleepHours(_ start: Date) async -> [String: Double] {
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM].map(\.rawValue).reduce(into: []) { $0.insert($1) }
        let q = HKSampleQueryDescriptor(predicates: [.categorySample(type: sleepType, predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        var byDay: [String: [(Date, Date)]] = [:]
        for s in (try? await q.result(for: store)) ?? [] where asleep.contains(s.value) { byDay[dayKey(s.endDate), default: []].append((s.startDate, s.endDate)) }
        return byDay.mapValues { iv in
            var total = 0.0, cur: (Date, Date)?
            for (a, b) in iv.sorted(by: { $0.0 < $1.0 }) {
                if let c = cur, a <= c.1 { cur = (c.0, max(c.1, b)) } else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = (a, b) }
            }
            if let c = cur { total += c.1.timeIntervalSince(c.0) }
            return total / 3600
        }
    }

    private func bodyMass(_ start: Date) async -> [String: Double] {
        let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: mass, predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        var out: [String: Double] = [:]
        for s in (try? await q.result(for: store)) ?? [] { out[dayKey(s.startDate)] = s.quantity.doubleValue(for: .gramUnit(with: .kilo)) }
        return out
    }

    private func latest(_ t: HKQuantityType, _ unit: HKUnit) async -> (String, Double)? {
        let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: t)], sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1)
        guard let s = try? await q.result(for: store).first else { return nil }
        return (dayKey(s.startDate), s.quantity.doubleValue(for: unit))
    }

    private func fetchWorkouts(_ start: Date) async -> [HKWorkoutItem] {
        let q = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: nil))],
                                        sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)])
        return ((try? await q.result(for: store)) ?? []).map { w in
            let kcal = w.statistics(for: active)?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            return HKWorkoutItem(id: w.uuid, date: dayKey(w.startDate), type: w.workoutActivityType.zh,
                                 minutes: w.duration / 60, kcal: kcal)
        }
    }

    private func at(_ date: String) -> Date { date == dayKey() ? Date.now : (ISO.date(date) ?? .now).addingTimeInterval(12 * 3600) }  // 补记往日按当天中午

    func writeIntake(kcal: Double, date: String) async {
        guard store.authorizationStatus(for: diet) == .sharingAuthorized else { return }
        let d = at(date)
        try? await store.save(HKQuantitySample(type: diet, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: d, end: d))
    }

    func writeWeight(_ kg: Double, date: String) async {
        guard store.authorizationStatus(for: mass) == .sharingAuthorized else { return }
        let d = at(date)
        try? await store.save(HKQuantitySample(type: mass, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg), start: d, end: d))
    }

    func writeWater(_ ml: Double, date: String) async -> UUID? {
        guard store.authorizationStatus(for: waterType) == .sharingAuthorized else { return nil }
        let d = at(date), s = HKQuantitySample(type: waterType, quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: ml), start: d, end: d)
        return (try? await store.save(s)) != nil ? s.uuid : nil
    }

    func deleteWater(_ id: UUID) async {
        _ = try? await store.deleteObjects(of: waterType, predicate: HKQuery.predicateForObject(with: id))
    }
}

extension HKWorkoutActivityType {
    var zh: String {
        switch self {
        case .running: "跑步"; case .walking: "步行"; case .cycling: "骑行"; case .swimming: "游泳"; case .hiking: "徒步"
        case .tennis: "网球"; case .badminton: "羽毛球"; case .tableTennis: "乒乓球"; case .squash, .racquetball: "壁球"; case .pickleball: "匹克球"
        case .basketball: "篮球"; case .soccer: "足球"; case .volleyball: "排球"; case .golf: "高尔夫"; case .baseball, .softball: "棒球"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "力量训练"; case .coreTraining: "核心训练"; case .crossTraining: "交叉训练"
        case .highIntensityIntervalTraining: "HIIT"; case .mixedCardio: "有氧训练"; case .jumpRope: "跳绳"; case .elliptical: "椭圆机"
        case .rowing: "划船"; case .stairClimbing, .stairs: "爬楼"; case .stepTraining: "踏板操"; case .climbing: "攀岩"
        case .yoga: "瑜伽"; case .pilates: "普拉提"; case .flexibility: "拉伸"; case .cooldown: "放松"; case .mindAndBody: "身心训练"; case .taiChi: "太极"
        case .dance, .socialDance, .cardioDance: "舞蹈"; case .barre: "芭蕾形体"; case .boxing, .kickboxing: "拳击"; case .martialArts: "武术"
        case .underwaterDiving: "潜水"; case .surfingSports: "冲浪"; case .paddleSports: "划桨"; case .waterSports: "水上运动"; case .sailing: "帆船"
        case .downhillSkiing, .crossCountrySkiing, .snowboarding, .snowSports: "滑雪"; case .skatingSports: "滑冰"
        default: "运动"
        }
    }
}

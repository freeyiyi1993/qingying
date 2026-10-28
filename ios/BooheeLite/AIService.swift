import Foundation
import Security
import UIKit

// MARK: AI 识别：App 里直接调各家视觉模型，API Key 只存在本机钥匙串。
// 口径同 boohee_lite/photo.py：模型只认菜名和克数，热量按食物库换算，炒菜加 1 勺油，按置信度给区间。

enum AIProvider: String, CaseIterable, Identifiable {
    case openai, anthropic, gemini, deepseek, compatible, mac
    var id: String { rawValue }
    var name: String {
        switch self {
        case .openai: "OpenAI"; case .anthropic: "Anthropic（Claude）"; case .gemini: "Google Gemini"; case .deepseek: "DeepSeek"
        case .compatible: "OpenAI 兼容接口"; case .mac: "Mac 上的 boohee-lite"
        }
    }
    var defaultModel: String {
        switch self {
        case .openai: "gpt-5.5"; case .anthropic: "claude-sonnet-5-5"; case .gemini: "gemini-3.6-flash"
        case .deepseek: "deepseek-v4-flash-vision-exp"; case .compatible, .mac: ""
        }
    }
    // 下拉里的常用型号（第一个是默认值）；型号名来自各家官方文档，DeepSeek 识图目前只有实验模型
    var models: [String] {
        switch self {
        case .openai: ["gpt-5.5", "gpt-5", "gpt-5-mini"]; case .anthropic: ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
        case .gemini: ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-flash-latest"]; case .deepseek: ["deepseek-v4-flash-vision-exp"]
        case .compatible, .mac: []
        }
    }
    var defaultBase: String {
        switch self {
        case .openai: "https://api.openai.com/v1"; case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"; case .deepseek: "https://api.deepseek.com"
        case .compatible, .mac: ""
        }
    }
}

enum Keychain {
    private static let service = "dev.mindbar.boohee"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func get(_ account: String) -> String? {
        var q = query(account), item: CFTypeRef?
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ account: String, _ value: String?) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

struct AIConfig {
    let provider: AIProvider, model: String, base: String, key: String
    init(_ p: Profile) {
        let arg = UserDefaults.standard  // 测试用：启动参数 -aiProvider / -aiBaseURL / -aiKey 临时覆盖，只在内存里，不落盘
        provider = AIProvider(rawValue: arg.string(forKey: "aiProvider") ?? p.aiProvider ?? "") ?? .mac
        let m = (p.aiModel ?? "").trimmingCharacters(in: .whitespaces), b = (arg.string(forKey: "aiBaseURL") ?? p.aiBaseURL ?? "").trimmingCharacters(in: .whitespaces)
        model = m.isEmpty ? provider.defaultModel : m
        base = String((b.isEmpty ? provider.defaultBase : b).reversed().drop { $0 == "/" }.reversed())
        key = arg.string(forKey: "aiKey") ?? Keychain.get("ai.\(provider.rawValue)") ?? ""
    }
    var label: String { provider == .mac ? provider.name : "\(provider.name) · \(model)" }
}

enum AI {
    static let prompt = """
    识别图片里的每一种食物，并估计可食部分的重量。
    只输出一个 JSON，不要任何解释：
    {"items":[{"name":"中文常用菜名或食材名","grams":估计克数,"kcal_per_100g":你估计的每100克热量,"cooked_with_oil":是否炒/煎/炸或明显有油汤,"confidence":"high|medium|low"}],"portion_anchor":图里是否有筷子/勺/手/标准碗等可判断份量的参照物}
    同一盘混合菜（如番茄炒蛋）算一项，不要拆成食材。
    """
    static let note = "拍照估算公开测试普遍偏低（NIH 初步结果，未同行评审）；酱汁和油看不见，按需上调。"
    static let range = ["high": 0.15, "medium": 0.25, "low": 0.4], order = ["low", "medium", "high"]

    // 修正结果：带上次结果和用户的一句话纠正重新识别（同 photo.py 的 REFINE）
    static func refine(_ hint: String, _ previous: [PhotoItem]) -> String {
        "\n上一次识别结果：\(previous.map { "\($0.name) \(Int($0.grams))g" }.joined(separator: "、"))\n用户纠正：\(hint)\n以用户的纠正为准（食物名称、份量、做法），用户没提到的部分重新看图判断，按同样的 JSON 格式输出完整结果。"
    }

    static func recognize(_ image: UIImage, config c: AIConfig, foods: [Food], hint: String? = nil, previous: [PhotoItem] = []) async throws -> PhotoEstimate {
        guard !c.key.isEmpty else { throw ServiceError("先在「我的 → AI 识别」里填 \(c.provider.name) 的 API Key") }
        guard !c.model.isEmpty, !c.base.isEmpty else { throw ServiceError("先在「我的 → AI 识别」里填模型名和接口地址") }
        guard let jpg = image.resized(maxSide: 1600).jpegData(compressionQuality: 0.7) else { throw ServiceError("照片读取失败") }
        let text = prompt + (hint.map { refine($0, previous) } ?? "")
        return try estimate(try await call(c, text: text, jpeg: jpg.base64EncodedString()), foods: foods)
    }

    static func call(_ c: AIConfig, text: String, jpeg b64: String) async throws -> String {
        let path: String, body: [String: Any], headers: [String: String]
        switch c.provider {
        case .anthropic:
            path = "/messages"; headers = ["x-api-key": c.key, "anthropic-version": "2023-06-01"]
            body = ["model": c.model, "max_tokens": 1024, "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]], ["type": "text", "text": text]]]]]
        case .gemini:
            path = "/models/\(c.model):generateContent"; headers = ["x-goog-api-key": c.key]
            body = ["contents": [["role": "user", "parts": [["text": text], ["inline_data": ["mime_type": "image/jpeg", "data": b64]]]]],
                    "generationConfig": ["responseMimeType": "application/json"]]
        default:  // OpenAI / DeepSeek / 兼容接口：chat/completions，图片用 data URL
            path = "/chat/completions"; headers = ["Authorization": "Bearer \(c.key)"]
            body = ["model": c.model, "messages": [["role": "user", "content": [
                ["type": "text", "text": text], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + b64]]]]]]
        }
        guard let url = URL(string: c.base + path) else { throw ServiceError("接口地址无效：\(c.base)") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let res: (Data, URLResponse)
        do { res = try await URLSession.shared.data(for: req) } catch { throw ServiceError("连不上 \(c.provider.name)：\(error.localizedDescription)") }
        let (d, r) = res, code = (r as? HTTPURLResponse)?.statusCode ?? 0
        let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        guard code == 200 else {
            let msg = ((j?["error"] as? [String: Any])?["message"] as? String) ?? (j?["error"] as? String) ?? String(decoding: d.prefix(200), as: UTF8.self)
            throw ServiceError("\(c.provider.name) 返回 HTTP \(code)：\(msg)")
        }
        let out: String? = switch c.provider {
        case .anthropic: (j?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        case .gemini: (((j?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        default: ((j?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let out, !out.isEmpty else { throw ServiceError("\(c.provider.name) 没有返回文字结果") }
        return out
    }

    // 同 photo.py build_estimate：库里有的按库换算；库里没有的用模型估的每 100g 热量，置信度降为低；没有份量参照物时最高到中
    static func estimate(_ raw: String, foods: [Food]) throws -> PhotoEstimate {
        guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"), a < b,
              let j = try? JSONSerialization.jsonObject(with: Data(raw[a...b].utf8)) as? [String: Any]
        else { throw ServiceError("模型没有返回 JSON：\(raw.prefix(120))") }
        let anchor = flag(j["portion_anchor"])
        var items: [PhotoItem] = [], oily = false
        for it in j["items"] as? [[String: Any]] ?? [] {
            let name = (it["name"] as? String) ?? "未知食物", grams = num(it["grams"]), food = findFood(name, in: foods)
            var conf = (it["confidence"] as? String).flatMap { range[$0] != nil ? $0 : nil } ?? "medium"
            if food == nil { conf = "low" }
            if !anchor && conf == "high" { conf = "medium" }
            oily = oily || (flag(it["cooked_with_oil"]) && (food?.oily ?? true))
            let f = grams / 100, per = food.map { ($0.kcal, $0.carb, $0.protein, $0.fat) } ?? (num(it["kcal_per_100g"]), 0, 0, 0)
            items.append(PhotoItem(name: name, grams: grams.rounded(), kcal: (per.0 * f).rounded(), carb: r1(per.1 * f), protein: r1(per.2 * f), fat: r1(per.3 * f), confidence: conf))
        }
        let oil = oily ? 1.0 : 0, total = items.reduce(0) { $0 + $1.kcal } + oil * 10 * 8.99
        let overall = items.map(\.confidence).min { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } ?? "low", r = range[overall]!
        return PhotoEstimate(items: items, oil_spoons: oil, kcal_low: r10(total * (1 - r)), kcal_mid: r10(total), kcal_high: r10(total * (1 + r)),
                             confidence: overall, note: note, photo_id: nil)
    }

    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double((v as? String ?? "").filter { "0123456789.".contains($0) }) ?? 0 }
    static func flag(_ v: Any?) -> Bool { (v as? Bool) ?? ["true", "yes", "是", "有"].contains((v as? String ?? "").lowercased()) }
    static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}

extension UIImage {
    // 相机原图 4000px 级别，传之前缩到长边 1600，省流量也省 token
    func resized(maxSide: CGFloat) -> UIImage {
        let s = max(size.width, size.height)
        guard s > maxSide else { return self }
        let k = maxSide / s, sz = CGSize(width: size.width * k, height: size.height * k), fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: sz, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: sz)) }
    }
}

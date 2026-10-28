import AuthenticationServices
import BackgroundTasks
import CryptoKit
import Foundation
import UIKit

// MARK: 云同步（Firebase）：Google 账号登录（系统网页登录窗口 + OAuth PKCE → Firebase signInWithIdp），整份数据 zlib 压缩后存在 Firestore 的 users/{uid} 一个文档里。
// 只有本人能读写（规则见 firebase/firestore.rules）；本机 JSON 是主存储，凌晨后台任务或手动「立即同步」时整份上传覆盖云端。
// 不引入 Firebase / Google SDK：只用到登录、换 token、读写一个文档，REST 足够，包体和编译时间都不涨。

struct FirebaseConfig {
    let apiKey: String, projectID: String, bundleID: String, clientID: String?, reversedClientID: String?
    // GoogleService-Info.plist 在 gitignore 的 data/firebase/ 里，缺它时云同步显示「未配置」
    static let shared: FirebaseConfig? = {
        guard let u = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"), let d = NSDictionary(contentsOf: u),
              let k = d["API_KEY"] as? String, let p = d["PROJECT_ID"] as? String else { return nil }
        return FirebaseConfig(apiKey: k, projectID: p, bundleID: d["BUNDLE_ID"] as? String ?? Bundle.main.bundleIdentifier ?? "",
                              clientID: d["CLIENT_ID"] as? String, reversedClientID: d["REVERSED_CLIENT_ID"] as? String)
    }()
}

@MainActor
final class Cloud: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var email = UserDefaults.standard.string(forKey: "cloud.email")
    @Published var status = ""
    @Published var busy = false
    private var uid = UserDefaults.standard.string(forKey: "cloud.uid")
    private var idToken: String?, expiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?  // 登录窗口进行中要强引用住，否则会被提前释放
    let config = FirebaseConfig.shared
    var signedIn: Bool { email != nil && uid != nil }

    // MARK: Google 登录

    var googleReady: Bool { config?.clientID != nil && config?.reversedClientID != nil }

    func signInWithGoogle() async -> Bool {
        guard let c = config, let cid = c.clientID, let scheme = c.reversedClientID else { status = "Google 登录还没配置好"; return false }
        busy = true; defer { busy = false }
        do {
            let verifier = Self.random(32), state = Self.random(16), redirect = "\(scheme):/oauth2redirect"
            var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            auth.queryItems = [.init(name: "client_id", value: cid), .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
                               .init(name: "scope", value: "openid email profile"), .init(name: "code_challenge", value: Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
                               .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state), .init(name: "prompt", value: "select_account")]
            let back = URLComponents(url: try await webAuth(auth.url!, scheme: scheme), resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard back.first(where: { $0.name == "state" })?.value == state, let code = back.first(where: { $0.name == "code" })?.value else {
                throw ServiceError("Google 没有返回授权码：\(back.first { $0.name == "error" }?.value ?? "未知原因")")
            }
            // 授权码换 Google id_token（iOS 客户端不需要 client secret）
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["client_id": cid, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"])
            guard let gid = try await send(req)["id_token"] as? String else { throw ServiceError("Google 没有返回 id_token") }
            // 再交给 Firebase 换成本项目的用户
            let j = try await post("https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp",
                                   json: ["postBody": "id_token=\(gid)&providerId=google.com", "requestUri": "http://localhost", "returnSecureToken": true])
            guard let id = j["idToken"] as? String, let refresh = j["refreshToken"] as? String, let u = j["localId"] as? String else { throw ServiceError("登录返回缺字段") }
            Keychain.set("cloud.refresh", refresh)
            idToken = id; expiry = Date.now.addingTimeInterval((Double(j["expiresIn"] as? String ?? "3600") ?? 3600) - 60)
            let mail = j["email"] as? String ?? "Google 账号"
            uid = u; email = mail
            UserDefaults.standard.set(mail, forKey: "cloud.email"); UserDefaults.standard.set(u, forKey: "cloud.uid")
            status = "已登录"
            return true
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            status = ""; return false
        } catch { print("Google 登录失败：\(error)"); status = "登录没有完成，请再试一次"; return false }  // 原因只写日志
    }

    private func webAuth(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] u, e in
                self?.authSession = nil
                if let u { cont.resume(returning: u) } else { cont.resume(throwing: e ?? ServiceError("登录没有完成")) }
            }
            s.presentationContextProvider = self
            authSession = s
            s.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor() }
    }

    static func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func random(_ n: Int) -> String { var b = [UInt8](repeating: 0, count: n); _ = SecRandomCopyBytes(kSecRandomDefault, n, &b); return b64url(Data(b)) }
    static func form(_ kv: [String: String]) -> Data {
        var c = URLComponents(); c.queryItems = kv.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }

    func signOut() {
        Keychain.set("cloud.refresh", nil); idToken = nil; uid = nil; email = nil
        UserDefaults.standard.removeObject(forKey: "cloud.email"); UserDefaults.standard.removeObject(forKey: "cloud.uid"); UserDefaults.standard.removeObject(forKey: "cloud.lastSync")
        status = "已退出；本机数据保留"
    }

    private func token() async throws -> String {
        if let t = idToken, expiry > .now { return t }
        guard let r = Keychain.get("cloud.refresh"), let c = config else { throw ServiceError("登录已失效，请重新登录") }
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(c.apiKey)")!)
        req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(c.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(r)".utf8)
        let j = try await send(req)
        guard let t = j["id_token"] as? String else { throw ServiceError("换 token 失败") }
        if let nr = j["refresh_token"] as? String { Keychain.set("cloud.refresh", nr) }
        idToken = t; expiry = Date.now.addingTimeInterval((Double(j["expires_in"] as? String ?? "3600") ?? 3600) - 60)
        return t
    }

    // MARK: 读写 users/{uid}

    private var docURL: URL? { config.flatMap { c in uid.flatMap { URL(string: "https://firestore.googleapis.com/v1/projects/\(c.projectID)/databases/(default)/documents/users/\($0)") } } }

    func upload(_ data: DataFile) async {
        guard signedIn, let url = docURL else { return }
        do {
            let raw = try JSONEncoder().encode(data), z = try (raw as NSData).compressed(using: .zlib) as Data
            var req = URLRequest(url: url); req.httpMethod = "PATCH"
            req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": [
                "data": ["stringValue": z.base64EncodedString()], "format": ["stringValue": "zlib+json v1"],
                "updatedAt": ["timestampValue": ISO8601DateFormatter().string(from: .now)], "device": ["stringValue": UIDevice.current.name]]])
            _ = try await send(req)
            UserDefaults.standard.set(Date.now, forKey: "cloud.lastSync")
            status = "已同步 \(Date.now.formatted(date: .omitted, time: .standard)) · 饮食 \(data.logs.count) 条 · 身体 \(data.body.count) 天 · 运动 \(data.workouts.count) 次（\(z.count / 1024 + 1) KB）"
        } catch { status = "上传失败：\(error.localizedDescription)" }
    }

    func download() async throws -> DataFile? {
        guard let url = docURL else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }  // 云端还没有数据
        guard code == 200, let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let b64 = ((j["fields"] as? [String: Any])?["data"] as? [String: Any])?["stringValue"] as? String,
              let z = Data(base64Encoded: b64) else { throw ServiceError("读取云端数据失败（HTTP \(code)）") }
        return try JSONDecoder().decode(DataFile.self, from: try (z as NSData).decompressed(using: .zlib) as Data)
    }

    // 删除所有数据：删掉 users/{uid} 这个文档
    func deleteRemote() async throws {
        guard let url = docURL else { return }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        _ = try await send(req)
    }

    // 凌晨备份：约好下一个 3:00 之后的后台刷新，具体时间由系统定（从多任务里划掉 App 后不会跑）
    nonisolated static let backupTask = "dev.mindbar.boohee.backup"
    nonisolated static func scheduleBackup() {
        let r = BGAppRefreshTaskRequest(identifier: backupTask)
        r.earliestBeginDate = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 3), matchingPolicy: .nextTime)
        try? BGTaskScheduler.shared.submit(r)
    }

    // MARK: HTTP

    private func post(_ url: String, json: [String: Any]) async throws -> [String: Any] {
        guard let c = config, let u = URL(string: "\(url)?key=\(c.apiKey)") else { throw ServiceError("云同步未配置") }
        var req = URLRequest(url: u); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.setValue(c.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let res: (Data, URLResponse)
        do { res = try await URLSession.shared.data(for: req) } catch { throw ServiceError("连不上 Firebase：\(error.localizedDescription)") }
        let (d, r) = res, code = (r as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard code == 200 else {
            let m = ((j["error"] as? [String: Any])?["message"] as? String) ?? (j["error"] as? String) ?? "HTTP \(code)"  // Google OAuth 的 error 是字符串
            throw ServiceError(Self.zh[m.components(separatedBy: " ").first ?? m] ?? m)
        }
        return j
    }

    static let zh = ["INVALID_IDP_RESPONSE": "Google 登录凭证无效，请重试", "OPERATION_NOT_ALLOWED": "Firebase 还没开启 Google 登录",
                     "TOO_MANY_ATTEMPTS_TRY_LATER": "尝试次数太多，过一会再试", "USER_DISABLED": "这个账号已被停用",
                     "invalid_grant": "Google 授权已过期，请重新登录", "TOKEN_EXPIRED": "登录已过期，请重新登录"]
}

// 合并两份数据：记录按 id 取并集（同 id 以本机为准），食物按名称；资料和方案以本机为准，本机没有方案时用云端的
func mergeData(_ local: DataFile, _ remote: DataFile) -> DataFile {
    func union<T: Identifiable>(_ a: [T], _ b: [T]) -> [T] { let ids = Set(a.map(\.id)); return a + b.filter { !ids.contains($0.id) } }
    var m = local
    m.foods = union(local.foods, remote.foods); m.logs = union(local.logs, remote.logs); m.body = union(local.body, remote.body)
    m.workouts = union(local.workouts, remote.workouts)
    m.estimates = union(local.estimates ?? [], remote.estimates ?? []); m.waters = union(local.waters ?? [], remote.waters ?? [])
    m.sleeps = union(local.sleeps ?? [], remote.sleeps ?? []); m.steps = union(local.steps ?? [], remote.steps ?? []); m.plans = union(local.plans ?? [], remote.plans ?? [])
    m.plan = local.plan ?? remote.plan
    return m
}

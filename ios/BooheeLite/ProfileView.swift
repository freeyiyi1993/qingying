import SwiftUI
import UniformTypeIdentifiers

// MARK: 我的：账号（Google 登录 + 云同步）→ 健康 App → 个人资料 → AI 识别 → 数据（导出 / 隐私 / 删除所有数据）

enum ProfileSheet: String, Identifiable { case birth, height, body, privacy; var id: String { rawValue } }

struct ProfileView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var health: HealthService
    @State var sheet: ProfileSheet?
    @State var key = ""
    @State var customModel = false
    @State var showDetail = false
    @State var confirmDelete = false

    var body: some View {
        let ai = AIProvider(rawValue: store.data.profile.aiProvider ?? "") ?? .mac, p = store.data.profile
        NavigationStack {
            Form {
                if store.cloud.config != nil && store.cloud.googleReady { CloudSection(cloud: store.cloud) }  // 没配 Firebase 的包不显示账号
                Section("健康 App") {
                    if !health.available {
                        Text(health.status).font(.footnote).foregroundStyle(Theme.ink7)
                    } else if health.noData {
                        // 读不到数据 = 权限被关：系统不会再弹授权，点「同步」没反应，只留一行去设置
                        CardRow(title: "没有读到健康数据", value: "去设置", action: openSettings)
                    } else {
                        Button { showDetail.toggle() } label: {
                            HStack { Text(health.status).foregroundStyle(Theme.ink); Spacer(); if health.syncing { ProgressView() } }
                        }
                        if showDetail && !health.detail.isEmpty { Text(health.detail).font(.footnote).foregroundStyle(Theme.ink7) }
                        Button("同步健康数据") { Task { await health.authorize() } }.disabled(health.syncing)
                    }
                }
                Section("个人资料") {
                    Picker("性别", selection: $store.data.profile.sex) { Text("男").tag("male"); Text("女").tag("female") }
                    CardRow(title: "出生年", value: String(p.birthYear), tag: health.birthYear != nil ? "来自健康" : nil) { sheet = .birth }
                    CardRow(title: "身高", value: "\(Int(p.heightCm)) cm", tag: health.heightCm != nil ? "来自健康" : nil) { sheet = .height }
                    CardRow(title: "当前体重", value: store.weights().last.map { String(format: "%.1f kg", $0.weight) } ?? "去记录") { sheet = .body }
                    Picker("运动吃回比例", selection: $store.data.profile.eatBack) { ForEach(EAT_BACK_VALUES, id: \.self) { Text("\(Int($0 * 100))%").tag($0) } }
                }
                Section {
                    Picker("服务", selection: Binding(get: { ai.rawValue }, set: {
                        store.data.profile.aiProvider = $0; store.data.profile.aiModel = nil; store.data.profile.aiBaseURL = nil
                        key = Keychain.get("ai.\($0)") ?? ""; customModel = false
                    })) { ForEach(AIProvider.allCases) { Text($0.name).tag($0.rawValue) } }
                    if ai == .mac {
                        TextField("服务地址", text: $store.data.profile.photoServer).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    } else {
                        SecureField("API Key", text: $key).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onChange(of: key) { _, k in Keychain.set("ai.\(ai.rawValue)", k.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        DisclosureGroup("高级") {  // 模型、接口地址默认就能用，收起来
                            modelPicker(ai)
                            if ai == .compatible {
                                TextField("接口地址 https://…/v1", text: optional(\.aiBaseURL)).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                            }
                        }
                    }
                } header: { Text("AI 识别") } footer: { Text("拍照算热量时，照片会发给这里选的服务识别") }
                Section("数据") {
                    ShareLink(item: ExportFile(data: store.data), preview: SharePreview("轻盈全部记录.json")) { Label("导出全部记录", systemImage: "square.and.arrow.up") }
                    Button { sheet = .privacy } label: { Label("隐私说明", systemImage: "hand.raised") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除所有数据", systemImage: "trash") }
                }
                Section { LabeledContent("版本", value: "\(info("CFBundleShortVersionString"))（\(info("CFBundleVersion"))）") }
            }
            .environment(\.inForm, true)
            .toolbar(.hidden, for: .navigationBar).statusBarCover()
            .sheet(item: $sheet) { s in
                switch s {
                case .birth: GoalWheelSheet(title: "出生年", values: (1940...2015).map(Double.init), format: { String(Int($0)) },
                                            value: Binding(get: { Double(store.data.profile.birthYear) }, set: { store.data.profile.birthYear = Int($0); store.save() }))
                case .height: GoalWheelSheet(title: "身高", values: (130...220).map(Double.init), format: { "\(Int($0)) cm" },
                                             value: Binding(get: { store.data.profile.heightCm }, set: { store.data.profile.heightCm = $0; store.save() }))
                case .body: BodyEntrySheet()
                case .privacy: PrivacySheet()
                }
            }
            .alert("删除所有数据？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { Task { _ = await store.deleteAll() } }
                Button("取消", role: .cancel) {}
            } message: { Text("会删除本机和云端的所有记录、方案和照片，不能恢复。健康 App 里的数据不受影响。") }
            .onAppear { key = Keychain.get("ai.\(ai.rawValue)") ?? "" }
            .onDisappear { store.save() }
        }
    }

    // 模型：下拉选常用型号，「自定义」时再填名字
    @ViewBuilder func modelPicker(_ ai: AIProvider) -> some View {
        let cur = store.data.profile.aiModel ?? ai.defaultModel, custom = customModel || !ai.models.contains(cur)
        Picker("模型", selection: Binding(get: { custom ? "custom" : cur }, set: { v in
            if v == "custom" { customModel = true } else { customModel = false; store.data.profile.aiModel = v == ai.defaultModel ? nil : v }
        })) {
            ForEach(ai.models, id: \.self) { Text($0).tag($0) }
            Text("自定义…").tag("custom")
        }
        if custom { TextField("模型名", text: optional(\.aiModel)).autocorrectionDisabled().textInputAutocapitalization(.never) }
    }

    func optional(_ k: WritableKeyPath<Profile, String?>) -> Binding<String> {
        Binding(get: { store.data.profile[keyPath: k] ?? "" }, set: { store.data.profile[keyPath: k] = $0.isEmpty ? nil : $0 })
    }

    func info(_ k: String) -> String { Bundle.main.infoDictionary?[k] as? String ?? "?" }
}

// 导出：整份数据（JSON）走系统分享，用到时才写文件
struct ExportFile: Transferable {
    let data: DataFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { f in
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("轻盈-全部记录-\(dayKey()).json"), enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(f.data).write(to: u, options: .atomic)
            return SentTransferredFile(u)
        }
    }
}

struct PrivacySheet: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("记录存在这台手机上（App 的文稿目录）。没有广告，也没有统计 SDK。")
                Text("登录 Google 账号后，整份记录压缩后存到你的 Firebase 云端文档，只有你自己能读写；退出登录不删云端，「删除所有数据」会一起删掉。")
                Text("健康 App：读取活动能量、静息能量、步数、体能训练、睡眠、体重、身高、性别和出生年，用来算每天的消耗；写回你在这里记的饮食热量、体重和喝水。健康数据不上传。")
                Text("拍照算热量：照片发给你在「AI 识别」里选的服务（各家 AI 的 API，或你电脑上的识别服务），只用来识别这一次。")
            }
            .font(.subheadline).foregroundStyle(Theme.ink)
            .navigationTitle("隐私说明").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// 账号：Google 登录后整份数据存到自己的 Firebase 项目（users/{uid}，只有本人能读写）
struct CloudSection: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cloud: Cloud
    @State var confirmOut = false

    var body: some View {
        Section {
            if cloud.signedIn {
                LabeledContent("Google 账号", value: cloud.email ?? "")
                Button { Task { await store.syncNow() } } label: {
                    HStack { Text("立即同步"); Spacer(); if cloud.busy { ProgressView() } else { Text(short(cloud.status)).font(.footnote).foregroundStyle(Theme.ink7) } }
                }.disabled(cloud.busy)
                Button("退出登录", role: .destructive) { confirmOut = true }
            } else {
                Button { Task { await store.signIn() } } label: { Label("使用 Google 账号登录", systemImage: "person.badge.key.fill") }.disabled(cloud.busy)
                if !cloud.status.isEmpty { Text(cloud.status).font(.footnote).foregroundStyle(Theme.ink7) }
            }
        } header: { Text("账号") } footer: {
            if cloud.signedIn { Text("每天凌晨自动备份到云端，也可以随时点「立即同步」") } else { Text("登录后记录同步到你的 Google 账号，换手机不丢；不登录也能正常使用") }
        }
        .alert("退出登录？", isPresented: $confirmOut) {
            Button("退出", role: .destructive) { cloud.signOut() }
            Button("取消", role: .cancel) {}
        } message: { Text("退出后本机记录仍保留，不再同步到云端") }
        // 第一次登录时云端已有数据：资料和方案用哪边的（记录两边都保留）
        .confirmationDialog("云端已有记录", isPresented: Binding(get: { store.cloudChoice != nil }, set: { if !$0 { store.cloudChoice = nil } }), titleVisibility: .visible) {
            Button("用云端的资料和方案") { if let r = store.cloudChoice { store.cloudChoice = nil; Task { await store.adopt(r, useRemote: true) } } }
            Button("用这台手机的资料和方案") { if let r = store.cloudChoice { store.cloudChoice = nil; Task { await store.adopt(r, useRemote: false) } } }
        } message: { Text("饮食、身体、运动等记录两边会合并保留；个人资料和减重方案只能留一份") }
    }

    // 同步状态只写时间，明细太长
    func short(_ s: String) -> String { s.hasPrefix("已同步") ? String(s.split(separator: "·").first ?? "").trimmingCharacters(in: .whitespaces) : s }
}

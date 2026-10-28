import ApplicationLibrary
import Foundation
import Libbox
import Library
import NetworkExtension
import SwiftUI
import UIKit

// MARK: - Настройки

enum HorekConfig {
    struct AllowedHost {
        let host: String
        let port: Int
    }

    /// Разрешённые серверы подписки. Запасные домены добавлять сюда.
    static let allowedHosts: [AllowedHost] = [
        AllowedHost(host: "horekhost.duckdns.org", port: 30902),
    ]

    static let pathPrefix = "/sub/"
    static let profileName = "Хорёк VPN"

    /// Принимает только https://<разрешённый хост>:<порт>/sub/<токен>
    static func validate(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: text),
              comps.scheme?.lowercased() == "https",
              let host = comps.host?.lowercased(),
              comps.user == nil,
              comps.password == nil,
              comps.path.hasPrefix(pathPrefix),
              comps.path.count > pathPrefix.count
        else {
            return nil
        }
        let port = comps.port ?? 443
        guard allowedHosts.contains(where: { $0.host == host && $0.port == port }) else {
            return nil
        }
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }
}

// MARK: - Информация о подписке (заголовок subscription-userinfo из Marzban)

struct HorekSubscriptionInfo {
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: Date?

    var used: Int64 { upload + download }
    var isExpired: Bool {
        if let expire { return expire < Date() }
        return false
    }

    var isOutOfTraffic: Bool { total > 0 && used >= total }

    init?(header: String) {
        var found = false
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let value = Int64(kv[1]) else { continue }
            switch kv[0].lowercased() {
            case "upload":
                upload = value
                found = true
            case "download":
                download = value
                found = true
            case "total":
                total = value
                found = true
            case "expire":
                if value > 0 { expire = Date(timeIntervalSince1970: TimeInterval(value)) }
                found = true
            default:
                break
            }
        }
        if !found { return nil }
    }
}

enum HorekCheckResult {
    case ok(HorekSubscriptionInfo?)
    case revoked
    case unreachable
}

enum HorekSubscriptionChecker {
    static func check(_ url: URL) async -> HorekCheckResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("HorekVPN (sing-box)", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable
            }
            switch http.statusCode {
            case 200 ..< 300:
                let header = http.value(forHTTPHeaderField: "subscription-userinfo")
                return .ok(header.flatMap { HorekSubscriptionInfo(header: $0) })
            case 401, 403, 404:
                return .revoked
            default:
                return .unreachable
            }
        } catch {
            return .unreachable
        }
    }
}

// MARK: - Сессия (вход / выход)

@MainActor
final class HorekSession: ObservableObject {
    enum State {
        case loading
        case loggedOut
        case loggedIn
    }

    @Published var state: State = .loading
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var info: HorekSubscriptionInfo?
    private var subscriptionURL: URL?

    func bootstrap(_ environments: ExtensionEnvironments) async {
        let profiles = (try? await ProfileManager.list()) ?? []
        guard let first = profiles.first else {
            environments.emptyProfiles = true
            state = .loggedOut
            return
        }
        guard let remote = first.remoteURL, let url = HorekConfig.validate(remote) else {
            await logout(environments: environments)
            return
        }
        environments.emptyProfiles = false
        let selected = await SharedPreferences.selectedProfileID.get()
        if !profiles.contains(where: { $0.id == selected }) {
            await SharedPreferences.selectedProfileID.set(first.mustID)
        }
        subscriptionURL = url
        state = .loggedIn
        await ensureVPNInstalled(environments)
        await refresh(environments: environments)
    }

    func onForeground(_ environments: ExtensionEnvironments) async {
        await environments.reload()
        if state == .loggedIn {
            await refresh(environments: environments)
        }
    }

    func refresh(environments: ExtensionEnvironments) async {
        guard let url = subscriptionURL else { return }
        switch await HorekSubscriptionChecker.check(url) {
        case let .ok(newInfo):
            if let newInfo { info = newInfo }
        case .revoked:
            await logout(environments: environments, message: "Доступ закрыт. Войдите по новой ссылке из бота.")
        case .unreachable:
            break
        }
    }

    func handle(url: URL, environments: ExtensionEnvironments) async {
        guard state == .loggedOut else { return }
        var candidate: String?
        if url.scheme?.lowercased() == "https" {
            candidate = url.absoluteString
        } else if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            candidate = comps.queryItems?.first(where: { $0.name == "url" })?.value
        }
        guard let candidate else { return }
        await login(candidate, environments: environments)
    }

    func login(_ raw: String, environments: ExtensionEnvironments) async {
        errorMessage = nil
        guard let url = HorekConfig.validate(raw) else {
            errorMessage = "Это не ссылка Хорёк VPN. Скопируйте ссылку из бота целиком."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let content = try await HTTPClient.getStringAsync(url.absoluteString)
            try await BlockingIO.run {
                var error: NSError?
                LibboxCheckConfig(content, &error)
                if let error {
                    throw error
                }
            }
            await removeAllProfiles()
            let nextProfileID = try await ProfileManager.nextID()
            let directory = FilePath.sharedDirectory.appendingPathComponent("configs", isDirectory: true)
            let file = directory.appendingPathComponent("config_\(nextProfileID).json")
            try await BlockingIO.run {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try content.write(to: file, atomically: true, encoding: .utf8)
            }
            let profile = Profile(
                name: HorekConfig.profileName,
                type: .remote,
                path: file.relativePath,
                remoteURL: url.absoluteString,
                autoUpdate: true,
                autoUpdateInterval: 60,
                lastUpdated: Date()
            )
            try await ProfileManager.create(profile)
            await SharedPreferences.selectedProfileID.set(profile.mustID)
            try UIProfileUpdateTask.configure()
            environments.emptyProfiles = false
            subscriptionURL = url
            state = .loggedIn
            await ensureVPNInstalled(environments)
            await refresh(environments: environments)
        } catch {
            errorMessage = "Не удалось войти: \(error.localizedDescription)"
        }
    }

    func logout(environments: ExtensionEnvironments, message: String? = nil) async {
        if let profile = environments.extensionProfile {
            switch profile.status {
            case .connected, .connecting, .reasserting:
                try? await profile.stop()
            default:
                break
            }
        }
        await removeAllProfiles()
        environments.emptyProfiles = true
        subscriptionURL = nil
        info = nil
        errorMessage = message
        state = .loggedOut
    }

    func ensureVPNInstalled(_ environments: ExtensionEnvironments) async {
        await environments.reload()
        guard environments.extensionProfile == nil else { return }
        do {
            try await ExtensionProfile.install()
            await environments.reload()
        } catch {
            errorMessage = "Нужно разрешить добавление VPN-конфигурации: \(error.localizedDescription)"
        }
    }

    private func removeAllProfiles() async {
        let profiles = (try? await ProfileManager.list()) ?? []
        for profile in profiles {
            try? await ProfileManager.delete(profile)
        }
        let directory = FilePath.sharedDirectory.appendingPathComponent("configs", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        await SharedPreferences.selectedProfileID.set(-1)
    }
}

// MARK: - Экраны

struct HorekRootView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = HorekSession()

    var body: some View {
        ZStack {
            switch session.state {
            case .loading:
                ProgressView()
            case .loggedOut:
                HorekLoginView(session: session)
            case .loggedIn:
                HorekConnectView(session: session)
            }
        }
        .task {
            await session.bootstrap(environments)
        }
        .onOpenURL { url in
            Task { await session.handle(url: url, environments: environments) }
        }
        .onChangeCompat(of: scenePhase) { newValue in
            if newValue == .active {
                Task { await session.onForeground(environments) }
            }
        }
    }
}

struct HorekLoginView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @ObservedObject var session: HorekSession
    @State private var link = ""

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            Text("Хорёк VPN")
                .font(.largeTitle)
                .bold()
            Text("Вставьте ссылку доступа из Telegram-бота")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            TextField("https://…", text: $link)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            Button("Вставить из буфера") {
                if let text = UIPasteboard.general.string {
                    link = text
                }
            }
            Button {
                Task { await session.login(link, environments: environments) }
            } label: {
                if session.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Войти")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(link.isEmpty || session.isBusy)
            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
    }
}

struct HorekConnectView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @ObservedObject var session: HorekSession
    @State private var confirmLogout = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Хорёк VPN")
                .font(.title2)
                .bold()
            Spacer()
            if let profile = environments.extensionProfile {
                HorekConnectButton(profile: profile, session: session)
            } else {
                VStack(spacing: 12) {
                    Text("Нужно разрешить добавление VPN-конфигурации")
                        .multilineTextAlignment(.center)
                    Button("Разрешить") {
                        Task { await session.ensureVPNInstalled(environments) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
            HorekInfoCard(info: session.info)
            if let message = session.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            Button("Выйти", role: .destructive) {
                confirmLogout = true
            }
        }
        .padding()
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                Task { await session.logout(environments: environments) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }
}

struct HorekConnectButton: View {
    @ObservedObject var profile: ExtensionProfile
    @ObservedObject var session: HorekSession
    @State private var isStarting = false

    private var isOn: Bool {
        profile.status == .connected || profile.status == .connecting || profile.status == .reasserting
    }

    private var isBusy: Bool {
        profile.status == .disconnecting || profile.status == .invalid
    }

    private var circleColor: Color {
        switch profile.status {
        case .connected:
            return .green
        case .connecting, .reasserting, .disconnecting:
            return .orange
        default:
            return .gray
        }
    }

    private var statusText: String {
        switch profile.status {
        case .connected:
            return "Подключено"
        case .connecting:
            return "Подключение…"
        case .reasserting:
            return "Переподключение…"
        case .disconnecting:
            return "Отключение…"
        default:
            return "Отключено"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Button {
                Task { await toggle() }
            } label: {
                ZStack {
                    Circle()
                        .fill(circleColor)
                        .frame(width: 160, height: 160)
                    Image(systemName: "power")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .disabled(isBusy)
            Text(statusText)
                .font(.headline)
        }
        .onReceive(profile.$status) { status in
            guard isStarting else { return }
            if status == .disconnected {
                isStarting = false
                if #available(iOS 16.0, *) {
                    Task { @MainActor in
                        if let alert = await profile.checkLastDisconnectError() {
                            session.errorMessage = alert.message
                        }
                    }
                }
            } else if status == .connected {
                isStarting = false
            }
        }
    }

    private func toggle() async {
        session.errorMessage = nil
        do {
            if isOn {
                try await profile.stop()
            } else {
                isStarting = true
                try await profile.start()
            }
        } catch {
            isStarting = false
            session.errorMessage = error.localizedDescription
        }
    }
}

struct HorekInfoCard: View {
    let info: HorekSubscriptionInfo?

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    var body: some View {
        if let info {
            VStack(alignment: .leading, spacing: 8) {
                if info.isExpired {
                    Text("Подписка закончилась. Продлите её в боте.")
                        .foregroundColor(.red)
                } else if info.isOutOfTraffic {
                    Text("Трафик закончился. Пополните в боте.")
                        .foregroundColor(.red)
                }
                if let expire = info.expire {
                    Text("Действует до: \(expire.formatted(date: .abbreviated, time: .omitted))")
                }
                if info.total > 0 {
                    Text("Трафик: \(bytes(info.used)) из \(bytes(info.total))")
                } else {
                    Text("Трафик: \(bytes(info.used)) (без лимита)")
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(12)
        }
    }
}

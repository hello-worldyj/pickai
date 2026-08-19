import SwiftUI
import AppKit
import FirebaseCore
import FirebaseAuth
import GoogleSignIn

enum AppColorScheme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension Color {
    /// Same accent used on the website (picky-ai.web.app) so the two feel like one product.
    static let pickAccent = Color(red: 0x0a / 255, green: 0x84 / 255, blue: 0xff / 255)
}

private let historyDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

private let isoParser = ISO8601DateFormatter()

private func formattedDate(_ iso: String) -> String {
    guard let date = isoParser.date(from: iso) else { return iso }
    return historyDateFormatter.string(from: date)
}

struct HistoryRootView: View {
    @AppStorage("historyColorScheme") private var colorSchemeRaw = AppColorScheme.system.rawValue
    @State private var currentUser: User? = Auth.auth().currentUser
    @State private var authListenerHandle: AuthStateDidChangeListenerHandle?

    @State private var email = ""
    @State private var password = ""
    @State private var loginError: String?
    @State private var isSubmitting = false

    private var colorScheme: AppColorScheme {
        AppColorScheme(rawValue: colorSchemeRaw) ?? .system
    }

    var body: some View {
        Group {
            if let currentUser {
                HistoryListView(onLogout: { try? Auth.auth().signOut() })
                    .environment(\.currentUserEmail, currentUser.email ?? "")
            } else {
                loginView
            }
        }
        .preferredColorScheme(colorScheme.colorScheme)
        .onAppear {
            authListenerHandle = Auth.auth().addStateDidChangeListener { _, user in
                currentUser = user
            }
        }
    }

    private var loginView: some View {
        VStack(spacing: 16) {
            Text("Pick AI History").font(.title2.bold())
            Text("Sign in to see your history.")
                .foregroundStyle(.secondary)
                .font(.callout)

            Button(action: signInWithGoogle) {
                HStack {
                    Image(systemName: "globe")
                    Text("Continue with Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .frame(width: 260)

            HStack {
                Rectangle().fill(.separator).frame(height: 1)
                Text("or").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.separator).frame(height: 1)
            }
            .frame(width: 260)

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            HStack {
                Button("Sign In") { Task { await signIn() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.pickAccent)
                Button("Create Account") { Task { await signUp() } }
                    .buttonStyle(.bordered)
            }
            .disabled(email.isEmpty || password.isEmpty || isSubmitting)

            if let loginError {
                Text(loginError).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 340)
    }

    private func signInWithGoogle() {
        loginError = nil
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            NSLog("[PickAI] Google sign-in: no FirebaseApp clientID available")
            loginError = "Google sign-in failed — try again."
            return
        }
        guard let window = NSApplication.shared.keyWindow else {
            NSLog("[PickAI] Google sign-in: no key window to present from")
            loginError = "Google sign-in failed — try again."
            return
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: window) { result, error in
            if let error {
                NSLog("[PickAI] Google sign-in: GIDSignIn error: \(error)")
                loginError = "Google sign-in failed — try again."
                return
            }
            guard let result else {
                NSLog("[PickAI] Google sign-in: GIDSignIn returned no result and no error")
                loginError = "Google sign-in failed — try again."
                return
            }
            guard let idToken = result.user.idToken?.tokenString else {
                NSLog("[PickAI] Google sign-in: GIDSignIn result had no ID token")
                loginError = "Google sign-in failed — try again."
                return
            }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            Auth.auth().signIn(with: credential) { _, error in
                if let error {
                    NSLog("[PickAI] Google sign-in: Firebase signIn(with:) error: \(error)")
                    loginError = "Google sign-in failed — try again."
                }
            }
        }
    }

    private func signIn() async {
        isSubmitting = true
        loginError = nil
        defer { isSubmitting = false }
        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            loginError = "Wrong email or password."
        }
    }

    private func signUp() async {
        isSubmitting = true
        loginError = nil
        defer { isSubmitting = false }
        do {
            _ = try await Auth.auth().createUser(withEmail: email, password: password)
        } catch {
            loginError = "Couldn't create account — check the email and try again."
        }
    }
}

private struct CurrentUserEmailKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var currentUserEmail: String {
        get { self[CurrentUserEmailKey.self] }
        set { self[CurrentUserEmailKey.self] = newValue }
    }
}

struct HistoryListView: View {
    let onLogout: () -> Void

    @Environment(\.currentUserEmail) private var currentUserEmail
    @AppStorage("historyColorScheme") private var colorSchemeRaw = AppColorScheme.system.rawValue
    @State private var entries: [HistoryEntry] = []
    @State private var searchText = ""
    @State private var mode = ""
    @State private var order: HistorySortOrder = .desc
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var canLoadMore = false
    @State private var selectedEntry: HistoryEntry?
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 600, minHeight: 480)
        .task { await load(reset: true) }
        .sheet(item: $selectedEntry) { entry in
            HistoryDetailView(
                entry: entry,
                onDeleted: {
                    entries.removeAll { $0.id == entry.id }
                    selectedEntry = nil
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pick AI History").font(.headline)
                Spacer()
                Picker("", selection: $colorSchemeRaw) {
                    ForEach(AppColorScheme.allCases, id: \.rawValue) { scheme in
                        Text(scheme.label).tag(scheme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Text(currentUserEmail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                Button("Sign Out", action: onLogout)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.leading, 4)
            }
            HStack(spacing: 10) {
                TextField("Search questions and answers…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchText) { _ in debouncedSearch() }

                Picker("", selection: $mode) {
                    Text("All").tag("")
                    Text("Answer").tag("answer")
                    Text("Explain").tag("explain")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: mode) { _ in Task { await load(reset: true) } }

                Picker("", selection: $order) {
                    Text("Newest first").tag(HistorySortOrder.desc)
                    Text("Oldest first").tag(HistorySortOrder.asc)
                }
                .frame(width: 140)
                .onChange(of: order) { _ in Task { await load(reset: true) } }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            VStack(spacing: 12) {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Retry") { Task { await load(reset: true) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty && !isLoading {
            Text("No entries yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(entries) { entry in
                        HistoryCardView(entry: entry)
                            .onTapGesture { selectedEntry = entry }
                    }
                }
                .padding(16)
                if canLoadMore {
                    Button("Load more") { Task { await load(reset: false) } }
                        .padding(.bottom, 16)
                }
            }
        }
    }

    private func debouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
    }

    private func load(reset: Bool) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        let cursorId = reset ? nil : entries.last?.id
        do {
            let rows = try await HistoryAPIClient.fetchHistory(
                query: searchText.isEmpty ? nil : searchText,
                mode: mode.isEmpty ? nil : mode,
                order: order,
                cursorId: cursorId
            )
            if reset { entries = rows } else { entries.append(contentsOf: rows) }
            canLoadMore = rows.count >= 30
        } catch HistoryAPIError.unauthorized {
            onLogout()
        } catch {
            errorMessage = "Couldn't load history."
        }
    }
}

struct HistoryCardView: View {
    let entry: HistoryEntry
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.image_key != nil {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.15)
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()
            }
            HStack {
                Text(entry.mode.capitalized)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(entry.mode == "answer" ? Color.green : Color.purple)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                Spacer()
                Text(formattedDate(entry.created_at))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(entry.question ?? "(screenshot)")
                .font(.subheadline.bold())
                .lineLimit(2)
            Text(entry.answer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task { await loadImage() }
    }

    private func loadImage() async {
        guard let key = entry.image_key else { return }
        if let data = try? await HistoryAPIClient.fetchImage(imageKey: key) {
            image = NSImage(data: data)
        }
    }
}

struct HistoryDetailView: View {
    let entry: HistoryEntry
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if entry.image_key != nil {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView().frame(height: 160)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("\(entry.mode.capitalized) · \(formattedDate(entry.created_at))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.question ?? "(screenshot)").font(.title3.bold())
                Text(entry.answer)

                Divider().padding(.vertical, 8)

                if showDeleteConfirm {
                    HStack {
                        Text("Delete this entry?").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { showDeleteConfirm = false }
                        Button("Delete", role: .destructive) { Task { await performDelete() } }
                            .disabled(isDeleting)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Delete", role: .destructive) { showDeleteConfirm = true }
                    }
                }
                if let deleteError {
                    Text(deleteError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task { await loadImage() }
    }

    private func loadImage() async {
        guard let key = entry.image_key else { return }
        if let data = try? await HistoryAPIClient.fetchImage(imageKey: key) {
            image = NSImage(data: data)
        }
    }

    private func performDelete() async {
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await HistoryAPIClient.deleteEntry(id: entry.id)
            onDeleted()
        } catch {
            deleteError = "Couldn't delete — try again."
        }
    }
}

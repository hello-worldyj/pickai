import SwiftUI
import AppKit

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
    @State private var isSignedIn = FirebaseRestAuth.isSignedIn

    @State private var email = ""
    @State private var password = ""
    @State private var loginError: String?
    @State private var isSubmitting = false

    private var colorScheme: AppColorScheme {
        AppColorScheme(rawValue: colorSchemeRaw) ?? .system
    }

    var body: some View {
        Group {
            if isSignedIn {
                HistoryListView(onLogout: {
                    FirebaseRestAuth.signOut()
                    isSignedIn = false
                })
                .environment(\.currentUserEmail, FirebaseRestAuth.currentUserEmail ?? "")
            } else {
                loginView
            }
        }
        .preferredColorScheme(colorScheme.colorScheme)
    }

    private var loginView: some View {
        VStack(spacing: 16) {
            Text("Pick AI History").font(.title2.bold())
            Text("Sign in with your Pick AI account.")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            Button("Sign In") { Task { await signIn() } }
                .buttonStyle(.borderedProminent)
                .tint(.pickAccent)
                .disabled(email.isEmpty || password.isEmpty || isSubmitting)

            VStack(spacing: 2) {
                Text("Accounts can only be created at")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Link("picky-ai.web.app", destination: URL(string: "https://picky-ai.web.app")!)
                    .font(.caption)
            }
            .multilineTextAlignment(.center)
            .frame(width: 260)

            if let loginError {
                Text(loginError).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 340)
    }

    private func signIn() async {
        isSubmitting = true
        loginError = nil
        defer { isSubmitting = false }
        do {
            try await FirebaseRestAuth.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            isSignedIn = true
        } catch FirebaseRestAuth.AuthError.other(let message) {
            NSLog("[PickAI] native sign-in error: \(message)")
            loginError = "Sign-in failed: \(message)"
        } catch {
            NSLog("[PickAI] native sign-in error: \(error)")
            loginError = "Wrong email or password."
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
    @State private var latestKnownId: Int?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 600, minHeight: 480)
        .task { await load(reset: true) }
        .task { await pollForNewEntriesLoop() }
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
            // Live-update polling only tracks "newer than the top of the default view" —
            // only meaningful right after a from-scratch load of that exact view.
            if reset, order == .desc, searchText.isEmpty, mode.isEmpty, let first = rows.first {
                latestKnownId = first.id
            }
        } catch HistoryAPIError.unauthorized {
            onLogout()
        } catch {
            errorMessage = "Couldn't load history."
        }
    }

    /// Polls for entries newer than the top of the list and prepends them quietly, without
    /// disturbing scroll position, search text, or filters — only runs on the default
    /// newest-first/unfiltered view, where "what's new" is unambiguous. A full push/websocket
    /// setup would be overkill for this at personal scale; a short poll is imperceptible.
    private func pollForNewEntriesLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            guard let latestKnownId, order == .desc, searchText.isEmpty, mode.isEmpty else { continue }
            guard let rows = try? await HistoryAPIClient.fetchHistory(query: nil, mode: nil, order: .desc, cursorId: nil) else {
                continue
            }
            let newRows = rows.filter { $0.id > latestKnownId }
            guard !newRows.isEmpty else { continue }
            entries.insert(contentsOf: newRows, at: 0)
            self.latestKnownId = newRows.map(\.id).max()
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
                Text(entry.question ?? "(screenshot)")
                    .font(.title3.bold())
                    .textSelection(.enabled)
                Text(entry.answer)
                    .textSelection(.enabled)

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

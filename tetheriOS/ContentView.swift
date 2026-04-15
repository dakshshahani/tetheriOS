import SwiftUI

struct ContentView: View {
    @StateObject private var store = VaultStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        Group {
            if store.isConfigured {
                NavigationSplitView {
                    SidebarView(store: store)
                        .navigationTitle(store.repositoryName)
                        .toolbar {
                            ToolbarItemGroup(placement: .topBarTrailing) {
                                Button {
                                    Task {
                                        await store.refreshManually()
                                    }
                                } label: {
                                    if store.syncState == .idle {
                                        Label("Sync", systemImage: "arrow.clockwise")
                                    } else {
                                        HStack(spacing: 8) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Syncing")
                                        }
                                    }
                                }
                                .disabled(!store.canRefresh)

                                Button {
                                    showingSettings = true
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        }
                } detail: {
                    NoteDetailView(store: store)
                }
            } else {
                OnboardingView(store: store)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, isPresented: $showingSettings)
        }
        .task {
            await store.loadInitialDataIfNeeded()
        }
        .onChange(of: scenePhase, initial: false) { _, newValue in
            guard newValue == .active else {
                return
            }

            Task {
                await store.refreshFromForeground()
            }
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var store: VaultStore

    @State private var owner = ""
    @State private var repository = ""
    @State private var branch = ""
    @State private var token = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    private var canConnect: Bool {
        !isConnecting
            && !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub") {
                    TextField("Owner", text: $owner)

                    TextField("Repository", text: $repository)

                    TextField("Branch (optional)", text: $branch)

                    SecureField("Personal Access Token", text: $token)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        if isConnecting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Connecting")
                            }
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(!canConnect)
                }

                Section {
                    Text("Your token is stored in Keychain and used only on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect Vault")
        }
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await store.configureConnection(
                    owner: owner,
                    repository: repository,
                    branch: branch.isEmpty ? nil : branch,
                    token: token
                )
            } catch {
                errorMessage = error.localizedDescription
            }

            isConnecting = false
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: VaultStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Text(store.repositoryName)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        store.resetConnection()
                        isPresented = false
                    } label: {
                        Text("Reset Connection")
                    }
                } footer: {
                    Text("This removes your saved token and repository details from the device.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var store: VaultStore

    var body: some View {
        List {
            Section {
                Text("\(store.noteCount) notes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let treeData {
                NodeBranchView(nodes: treeData.tree, store: store)
            } else if store.syncState == .loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading notes")
                        .foregroundStyle(.secondary)
                }
            }

            if let treeError = store.treeError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Could not load vault")
                            .font(.headline)
                        Text(treeError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if store.isSearching {
                Section("Search Results") {
                    if store.searchResults.isEmpty {
                        Text("No notes found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.searchResults) { file in
                            Button {
                                Task {
                                    await store.selectFile(path: file.path)
                                }
                            } label: {
                                Label {
                                    Text(file.name)
                                        .fontWeight(store.activePath == file.path ? .semibold : .regular)
                                } icon: {
                                    Image(systemName: "doc.text")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.searchQuery, placement: .sidebar, prompt: "Search notes")
    }

    private var treeData: VaultTreeResponse? {
        if store.isSearching {
            return nil
        }

        return store.treeData
    }
}

private struct NodeBranchView: View {
    let nodes: [VaultNode]
    @ObservedObject var store: VaultStore

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .folder(let folder):
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { store.expandedFolders.contains(folder.path) },
                        set: { isExpanded in
                            let contains = store.expandedFolders.contains(folder.path)
                            if isExpanded != contains {
                                store.toggleFolder(path: folder.path)
                            }
                        }
                    )
                ) {
                    NodeBranchView(nodes: folder.children, store: store)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }

            case .file(let file):
                Button {
                    Task {
                        await store.selectFile(path: file.path)
                    }
                } label: {
                    Label {
                        Text(file.name)
                            .fontWeight(store.activePath == file.path ? .semibold : .regular)
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct NoteDetailView: View {
    @ObservedObject var store: VaultStore

    var body: some View {
        let title = noteTitle

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.isLoadingFile {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading note")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 48)
                } else if let fileError = store.fileError {
                    ContentUnavailableView {
                        Label("Could not load note", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(fileError)
                    }
                } else if let renderedNote = store.renderedNote {
                    NoteMetadataView(frontmatter: renderedNote.frontmatter)
                    NoteMarkdownView(markdown: renderedNote.content)
                } else {
                    ContentUnavailableView {
                        Label("Welcome to Tether Vault", systemImage: "brain.head.profile")
                    } description: {
                        Text("Select a note from the sidebar to begin.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction { url in
            if store.handleMarkdownLink(url.absoluteString) {
                return .handled
            }

            return .systemAction(url)
        })
    }

    private var noteTitle: String {
        guard let activePath = store.activePath else {
            return "Vault"
        }

        return activePath.split(separator: "/").last.map(String.init) ?? "Vault"
    }
}

private struct NoteMetadataView: View {
    let frontmatter: FrontmatterDisplay?

    var body: some View {
        if let frontmatter {
            VStack(alignment: .leading, spacing: 10) {
                if let date = frontmatter.date {
                    Label(date, systemImage: "calendar")
                }
                if let course = frontmatter.course {
                    MetadataLinkRow(icon: "book", value: course)
                }
                if let tags = frontmatter.tags {
                    Label(tags, systemImage: "tag")
                }
                if let links = frontmatter.links {
                    MetadataLinkRow(icon: "link", value: links)
                }
                if let author = frontmatter.author {
                    Label(author, systemImage: "person")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
    }
}

private struct MetadataLinkRow: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)

            if let attributed = try? AttributedString(markdown: value) {
                Text(attributed)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct NoteMarkdownView: View {
    let markdown: String

    var body: some View {
        MarkdownRenderer(markdown: markdown)
    }
}

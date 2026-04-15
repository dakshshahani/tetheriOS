import Foundation
import Combine

@MainActor
final class VaultStore: ObservableObject {
    enum SyncState {
        case idle
        case loading
        case refreshing
    }

    struct RenderedNote {
        let content: String
        let frontmatter: FrontmatterDisplay?
    }

    @Published private(set) var treeData: VaultTreeResponse?
    @Published private(set) var activeFile: VaultFileResponse?
    @Published private(set) var activePath: String?
    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var treeError: String?
    @Published private(set) var fileError: String?
    @Published private(set) var isLoadingFile = false
    @Published private(set) var isConfigured = false
    @Published private(set) var connectionTitle = "Vault"
    @Published var expandedFolders: Set<String> = []
    @Published var searchQuery = ""

    private let client: VaultAPIClient
    private let userDefaults: UserDefaults
    private var hasLoadedInitialData = false
    private let lastOpenedKey = "lastOpenedNotePath"

    init(client: VaultAPIClient? = nil, userDefaults: UserDefaults = .standard) {
        self.client = client ?? VaultAPIClient()
        self.userDefaults = userDefaults
        self.isConfigured = self.client.isConfigured()

        if let connection = self.client.currentConnection() {
            self.connectionTitle = connection.title
        }
    }

    var repositoryName: String {
        treeData?.repository ?? connectionTitle
    }

    var noteCount: Int {
        treeData?.files.count ?? 0
    }

    var canRefresh: Bool {
        syncState == .idle
    }

    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var renderedNote: RenderedNote? {
        guard let activeFile else {
            return nil
        }

        let parsed = VaultMarkdownProcessor.parseFrontmatter(activeFile.content)
        let wikiLookup = VaultMarkdownProcessor.buildWikiLookup(files: treeData?.files ?? [])
        let transformedContent = VaultMarkdownProcessor.transformObsidianMarkdown(parsed.content, lookup: wikiLookup)
        var displayFrontmatter = VaultMarkdownProcessor.formatFrontmatterDisplay(parsed.frontmatter)

        if var frontmatter = displayFrontmatter {
            if let course = frontmatter.course {
                frontmatter.course = VaultMarkdownProcessor.transformObsidianMarkdown(course, lookup: wikiLookup)
            }

            if let links = frontmatter.links {
                frontmatter.links = VaultMarkdownProcessor.transformObsidianMarkdown(links, lookup: wikiLookup)
            }

            displayFrontmatter = frontmatter
        }

        return RenderedNote(content: transformedContent, frontmatter: displayFrontmatter)
    }

    var searchResults: [MarkdownFileSummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return []
        }

        return treeData?.files.filter { $0.name.lowercased().contains(query) } ?? []
    }

    func loadInitialDataIfNeeded() async {
        guard !hasLoadedInitialData else {
            return
        }

        guard isConfigured else {
            return
        }

        hasLoadedInitialData = true
        await fetchTree(reason: .initial)
    }

    func configureConnection(owner: String, repository: String, branch: String?, token: String) async throws {
        try await client.configure(owner: owner, repository: repository, branch: branch, token: token)

        isConfigured = true
        hasLoadedInitialData = true
        treeError = nil
        fileError = nil

        if let connection = client.currentConnection() {
            connectionTitle = connection.title
        }

        await fetchTree(reason: .initial)
    }

    func resetConnection() {
        client.clearConnection()

        isConfigured = false
        hasLoadedInitialData = false
        connectionTitle = "Vault"

        treeData = nil
        activeFile = nil
        activePath = nil
        treeError = nil
        fileError = nil
        searchQuery = ""
        expandedFolders = []
        clearLastOpenedPath()
    }

    func refreshFromForeground() async {
        guard hasLoadedInitialData else {
            return
        }

        await fetchTree(reason: .refresh)
    }

    func refreshManually() async {
        await fetchTree(reason: .refresh)
    }

    func toggleFolder(path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
        }
    }

    func selectFile(path: String) async {
        activePath = path
        fileError = nil
        expandParentFolders(for: path)
        persistLastOpenedPath(path)
        await loadFile(path: path)
    }

    func handleMarkdownLink(_ href: String) -> Bool {
        guard let activePath else {
            return false
        }

        let decoded = href.removingPercentEncoding ?? href

        guard let resolved = VaultMarkdownProcessor.resolveMarkdownLink(currentPath: activePath, href: decoded) else {
            return false
        }

        let lookup = markdownPathLookup
        guard let canonicalPath = lookup[resolved.lowercased()], markdownPaths.contains(canonicalPath) else {
            return false
        }

        Task {
            await selectFile(path: canonicalPath)
        }

        return true
    }

    private enum FetchReason {
        case initial
        case refresh
    }

    private var markdownPaths: Set<String> {
        Set((treeData?.files ?? []).map { $0.path })
    }

    private var markdownPathLookup: [String: String] {
        var map: [String: String] = [:]
        for file in treeData?.files ?? [] {
            map[file.path.lowercased()] = file.path
        }
        return map
    }

    private func fetchTree(reason: FetchReason) async {
        guard isConfigured else {
            return
        }

        treeError = nil

        switch reason {
        case .initial:
            syncState = .loading
        case .refresh:
            syncState = .refreshing
        }

        do {
            let payload = try await client.fetchTree()
            treeData = payload

            if reason == .initial {
                await restoreLastOpenedPathIfPossible()
            } else {
                let stillExists = validateActiveSelectionStillExists()
                if stillExists, let activePath {
                    await loadFile(path: activePath)
                }
            }
        } catch {
            treeError = error.localizedDescription
        }

        syncState = .idle
    }

    private func loadFile(path: String) async {
        isLoadingFile = true
        fileError = nil

        do {
            let payload = try await client.fetchFile(path: path)
            activeFile = payload
        } catch {
            fileError = error.localizedDescription
        }

        isLoadingFile = false
    }

    private func restoreLastOpenedPathIfPossible() async {
        guard
            let treeData,
            let savedPath = userDefaults.string(forKey: lastOpenedKey),
            !savedPath.isEmpty,
            treeData.files.contains(where: { $0.path == savedPath })
        else {
            activePath = nil
            activeFile = nil
            return
        }

        expandParentFolders(for: savedPath)
        await selectFile(path: savedPath)
    }

    private func validateActiveSelectionStillExists() -> Bool {
        guard let treeData else {
            return false
        }

        guard let activePath else {
            return false
        }

        let stillExists = treeData.files.contains(where: { $0.path == activePath })
        if !stillExists {
            self.activePath = nil
            activeFile = nil
            clearLastOpenedPath()
        }

        return stillExists
    }

    private func expandParentFolders(for filePath: String) {
        let parts = filePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            return
        }

        var current = ""
        for part in parts.dropLast() {
            current = current.isEmpty ? part : "\(current)/\(part)"
            expandedFolders.insert(current)
        }
    }

    private func persistLastOpenedPath(_ path: String) {
        userDefaults.set(path, forKey: lastOpenedKey)
    }

    private func clearLastOpenedPath() {
        userDefaults.removeObject(forKey: lastOpenedKey)
    }
}

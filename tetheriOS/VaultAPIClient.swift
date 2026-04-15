import Foundation

struct GitHubVaultConfiguration: Codable, Equatable {
    let owner: String
    let repository: String
    let branch: String?
}

struct VaultConnectionDisplay {
    let owner: String
    let repository: String

    var title: String {
        "\(owner)/\(repository)"
    }
}

enum VaultClientError: LocalizedError {
    case missingConnection
    case invalidConfiguration
    case invalidResponse
    case invalidContent
    case truncatedTree
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingConnection:
            return "Connection not configured"
        case .invalidConfiguration:
            return "Invalid GitHub configuration"
        case .invalidResponse:
            return "Invalid GitHub response"
        case .invalidContent:
            return "Could not decode file content"
        case .truncatedTree:
            return "Vault is too large for a recursive tree sync"
        case .httpError(_, let message):
            return message
        }
    }
}

private struct GitHubRepoResponse: Decodable {
    let defaultBranch: String

    private enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
}

private struct GitHubTreeResponse: Decodable {
    struct Item: Decodable {
        let path: String
        let mode: String?
        let type: String
        let sha: String
        let size: Int?
        let url: String?
    }

    let sha: String
    let tree: [Item]
    let truncated: Bool
}

private struct GitHubFileResponse: Decodable {
    let path: String
    let sha: String
    let size: Int?
    let encoding: String?
    let content: String?
}

private struct GitHubAPIError: Decodable {
    let message: String?
}

@MainActor
final class VaultAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let connectionStore: VaultConnectionStore

    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        connectionStore: VaultConnectionStore = VaultConnectionStore()
    ) {
        self.session = session
        self.decoder = decoder
        self.connectionStore = connectionStore
    }

    func isConfigured() -> Bool {
        connectionStore.loadConnection() != nil
    }

    func currentConnection() -> VaultConnectionDisplay? {
        guard let connection = connectionStore.loadConnection() else {
            return nil
        }

        return VaultConnectionDisplay(owner: connection.owner, repository: connection.repository)
    }

    func clearConnection() {
        connectionStore.clearConnection()
    }

    func configure(owner: String, repository: String, branch: String?, token: String) async throws {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedOwner.isEmpty, !trimmedRepository.isEmpty, !trimmedToken.isEmpty else {
            throw VaultClientError.invalidConfiguration
        }

        let provisional = GitHubVaultConfiguration(
            owner: trimmedOwner,
            repository: trimmedRepository,
            branch: (trimmedBranch?.isEmpty ?? true) ? nil : trimmedBranch
        )

        try connectionStore.saveConnection(provisional, token: trimmedToken)

        do {
            _ = try await fetchTree()
        } catch {
            connectionStore.clearConnection()
            throw error
        }
    }

    func fetchTree() async throws -> VaultTreeResponse {
        let connection = try requireConnection()
        let branch = try await resolveBranch(configuration: connection.configuration, token: connection.token)
        let treeResponse: GitHubTreeResponse = try await requestDecodable(
            pathComponents: [
                "repos",
                connection.configuration.owner,
                connection.configuration.repository,
                "git",
                "trees",
                branch
            ],
            token: connection.token,
            queryItems: [URLQueryItem(name: "recursive", value: "1")]
        )

        if treeResponse.truncated {
            throw VaultClientError.truncatedTree
        }

        let markdownFiles: [MarkdownFileSummary] = treeResponse.tree
            .filter { item in
                item.type == "blob" && item.path.lowercased().hasSuffix(".md")
            }
            .map { item in
                MarkdownFileSummary(
                    name: item.path.split(separator: "/").last.map(String.init) ?? item.path,
                    path: item.path,
                    size: item.size ?? 0,
                    sha: item.sha
                )
            }
            .sorted { lhs, rhs in
                lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }

        let now = ISO8601DateFormatter().string(from: Date())
        return VaultTreeResponse(
            repository: "\(connection.configuration.owner)/\(connection.configuration.repository)",
            syncedAt: now,
            files: markdownFiles,
            tree: buildVaultTree(from: markdownFiles)
        )
    }

    func fetchFile(path: String) async throws -> VaultFileResponse {
        let connection = try requireConnection()
        let pathSegments = path.split(separator: "/").map(String.init)
        guard !pathSegments.isEmpty else {
            throw VaultClientError.invalidConfiguration
        }

        var queryItems: [URLQueryItem] = []

        if let branch = connection.configuration.branch, !branch.isEmpty {
            queryItems.append(URLQueryItem(name: "ref", value: branch))
        }

        let response: GitHubFileResponse = try await requestDecodable(
            pathComponents: [
                "repos",
                connection.configuration.owner,
                connection.configuration.repository,
                "contents"
            ] + pathSegments,
            token: connection.token,
            queryItems: queryItems.isEmpty ? nil : queryItems
        )

        guard
            let encoding = response.encoding?.lowercased(),
            encoding == "base64",
            let encodedContent = response.content
        else {
            throw VaultClientError.invalidContent
        }

        let cleaned = encodedContent.replacingOccurrences(of: "\n", with: "")
        guard
            let data = Data(base64Encoded: cleaned),
            let content = String(data: data, encoding: .utf8)
        else {
            throw VaultClientError.invalidContent
        }

        return VaultFileResponse(
            path: response.path,
            sha: response.sha,
            syncedAt: ISO8601DateFormatter().string(from: Date()),
            content: content
        )
    }

    private struct RequiredConnection {
        let configuration: GitHubVaultConfiguration
        let token: String
    }

    private func requireConnection() throws -> RequiredConnection {
        guard let configuration = connectionStore.loadConnection(),
              let token = connectionStore.loadToken(),
              !token.isEmpty else {
            throw VaultClientError.missingConnection
        }

        return RequiredConnection(configuration: configuration, token: token)
    }

    private func resolveBranch(configuration: GitHubVaultConfiguration, token: String) async throws -> String {
        if let branch = configuration.branch, !branch.isEmpty {
            return branch
        }

        let repository: GitHubRepoResponse = try await requestDecodable(
            pathComponents: ["repos", configuration.owner, configuration.repository],
            token: token
        )
        return repository.defaultBranch
    }

    private func requestDecodable<T: Decodable>(
        pathComponents: [String],
        token: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let encodedPath = pathComponents
            .filter { !$0.isEmpty }
            .map { segment in
                segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
            }
            .joined(separator: "/")

        guard !encodedPath.isEmpty else {
            throw VaultClientError.invalidConfiguration
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.percentEncodedPath = "/\(encodedPath)"
        components.queryItems = queryItems

        guard let url = components.url else {
            throw VaultClientError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VaultClientError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let fallback = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let payload = try? decoder.decode(GitHubAPIError.self, from: data)
            let message = payload?.message ?? fallback
            throw VaultClientError.httpError(statusCode: http.statusCode, message: message)
        }

        return try decoder.decode(T.self, from: data)
    }
}

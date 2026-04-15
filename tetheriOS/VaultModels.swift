import Foundation

struct MarkdownFileSummary: Codable, Hashable, Identifiable {
    let name: String
    let path: String
    let size: Int
    let sha: String

    var id: String { path }
}

struct VaultTreeResponse: Codable, Hashable {
    let repository: String
    let syncedAt: String
    let files: [MarkdownFileSummary]
    let tree: [VaultNode]
}

struct VaultFileResponse: Codable, Hashable {
    let path: String
    let sha: String
    let syncedAt: String
    let content: String
}

enum VaultNodeKind: String, Codable, Hashable {
    case folder
    case file
}

struct VaultFolderNode: Codable, Hashable, Identifiable {
    let kind: VaultNodeKind
    let name: String
    let path: String
    let children: [VaultNode]

    var id: String { path }
}

struct VaultFileNode: Codable, Hashable, Identifiable {
    let kind: VaultNodeKind
    let name: String
    let path: String

    var id: String { path }
}

enum VaultNode: Codable, Hashable, Identifiable {
    case folder(VaultFolderNode)
    case file(VaultFileNode)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    var id: String {
        switch self {
        case .folder(let folder):
            return folder.id
        case .file(let file):
            return file.id
        }
    }

    var kind: VaultNodeKind {
        switch self {
        case .folder:
            return .folder
        case .file:
            return .file
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(VaultNodeKind.self, forKey: .kind)

        switch kind {
        case .folder:
            self = .folder(try VaultFolderNode(from: decoder))
        case .file:
            self = .file(try VaultFileNode(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .folder(let folder):
            try folder.encode(to: encoder)
        case .file(let file):
            try file.encode(to: encoder)
        }
    }
}

func buildVaultTree(from files: [MarkdownFileSummary]) -> [VaultNode] {
    let sorted = files.sorted { lhs, rhs in
        lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    return buildNodes(from: sorted, parentPath: "")
}

private func buildNodes(from files: [MarkdownFileSummary], parentPath: String) -> [VaultNode] {
    var directFiles: [VaultFileNode] = []
    var subfolders: [String: [MarkdownFileSummary]] = [:]

    for file in files {
        let relativePath: String
        if parentPath.isEmpty {
            relativePath = file.path
        } else {
            let prefix = "\(parentPath)/"
            guard file.path.hasPrefix(prefix) else {
                continue
            }
            relativePath = String(file.path.dropFirst(prefix.count))
        }

        let parts = relativePath.split(separator: "/").map(String.init)
        guard let firstPart = parts.first else {
            continue
        }

        if parts.count == 1 {
            directFiles.append(
                VaultFileNode(
                    kind: .file,
                    name: firstPart,
                    path: file.path
                )
            )
        } else {
            subfolders[firstPart, default: []].append(file)
        }
    }

    let folderNodes: [VaultNode] = subfolders.keys
        .sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        .map { folderName in
            let path = parentPath.isEmpty ? folderName : "\(parentPath)/\(folderName)"
            let children = buildNodes(from: subfolders[folderName] ?? [], parentPath: path)
            return VaultNode.folder(
                VaultFolderNode(
                    kind: .folder,
                    name: folderName,
                    path: path,
                    children: children
                )
            )
        }

    let fileNodes = directFiles
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        .map(VaultNode.file)

    return folderNodes + fileNodes
}

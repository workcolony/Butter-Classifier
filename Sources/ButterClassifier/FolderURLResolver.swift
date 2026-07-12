import Foundation

enum FolderURLResolver {
    /// Resolves Finder aliases and symlinks to the folder they point at.
    static func resolve(_ url: URL) -> URL {
        if let alias = resolveAlias(url) { return alias }
        return url.resolvingSymlinksInPath()
    }

    static func resolvePath(_ path: String) -> String {
        resolve(URL(fileURLWithPath: path)).path
    }

    private static func resolveAlias(_ url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isAliasFileKey]),
              values.isAliasFile == true else { return nil }
        return try? URL(resolvingAliasFileAt: url)
    }
}

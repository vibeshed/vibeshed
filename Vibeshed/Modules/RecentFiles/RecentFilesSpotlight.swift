import Foundation

/// Where the module's files come from: Spotlight, or a fixed list in tests.
protocol RecentFilesSource: Sendable {
    /// Starts watching. Each element is the whole list, most recently used first: once
    /// when it's first gathered, then again whenever it changes.
    func start() -> AsyncStream<Result<[RecentFile], Error>>
    func stop()
}

enum RecentFilesError: LocalizedError {
    case spotlightUnavailable
    case notRecent(String)
    case couldNotOpen(String)
    case nothingChosen

    var errorDescription: String? {
        switch self {
        case .spotlightUnavailable: "Spotlight couldn't start the search for recent files"
        case let .notRecent(path): "\((path as NSString).lastPathComponent) isn't a recent file"
        case let .couldNotOpen(name): "Couldn't open \(name)"
        case .nothingChosen: "Nothing to open"
        }
    }
}

/// Finder's Recents, live: the Spotlight query behind it, kept running so the list
/// follows files as they're opened. Needs no permission and reads no file.
///
/// The query runs on its own serial queue, which `NSMetadataQuery` uses in place of a
/// run loop; every touch of the query happens there.
final class SpotlightRecentFiles: RecentFilesSource, @unchecked Sendable {
    /// The raw query of Finder's own Recents, from Finder.app's
    /// `Contents/Resources/MyLibraries/myDocuments.cannedSearch/Resources/search.savedSearch`.
    static let rawQuery = """
    (kMDItemLastUsedDate = "*") && ((kMDItemContentTypeTree = public.content) || \
    (kMDItemContentTypeTree = "com.microsoft.*"cdw) || (kMDItemContentTypeTree = public.archive))
    """

    /// The saved search's scope; the query takes the constant's string value.
    static let scope = "kMDQueryScopeMyFiles"

    /// Read through `value(ofAttribute:forResultAt:)` from what the query gathered.
    /// Asking each `NSMetadataItem` instead costs about 0.3 ms per file and attribute
    /// (over 100 ms per attribute for 389 files). The path and last-used date are
    /// cheap either way.
    static let gatheredAttributes = [NSMetadataItemContentTypeKey, "kMDItemLogicalSize"]

    private let home: String
    private let queue: OperationQueue

    // Touched only on `queue`.
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var continuation: AsyncStream<Result<[RecentFile], Error>>.Continuation?

    init(home: String = NSHomeDirectory()) {
        self.home = home
        queue = OperationQueue()
        queue.name = "Vibeshed.RecentFiles"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    func start() -> AsyncStream<Result<[RecentFile], Error>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Result<[RecentFile], Error>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        queue.addOperation { [self] in
            stopQuery()
            self.continuation = continuation
            guard let predicate = NSPredicate(fromMetadataQueryString: Self.rawQuery) else {
                finish(with: RecentFilesError.spotlightUnavailable)
                return
            }
            let query = NSMetadataQuery()
            query.operationQueue = queue
            query.predicate = predicate
            query.searchScopes = [Self.scope]
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
            query.valueListAttributes = Self.gatheredAttributes
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: query, queue: queue
                ) { [weak self] _ in
                    self?.publish()
                })
            }
            self.query = query
            if !query.start() {
                finish(with: RecentFilesError.spotlightUnavailable)
            }
        }
        return stream
    }

    func stop() {
        queue.addOperation { [self] in
            stopQuery()
        }
    }

    private func publish() {
        guard let query, let continuation else { return }
        query.disableUpdates()
        let files = Self.files(in: query, home: home)
        query.enableUpdates()
        continuation.yield(.success(files))
    }

    private func finish(with error: Error) {
        continuation?.yield(.failure(error))
        stopQuery()
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        continuation?.finish()
        continuation = nil
    }

    /// The query's results that Finder's Recents would list, in its order.
    private static func files(in query: NSMetadataQuery, home: String) -> [RecentFile] {
        (0 ..< query.resultCount).compactMap { index in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  RecentFilePaths.isListable(path, home: home),
                  let lastUsed = query.value(ofAttribute: NSMetadataItemLastUsedDateKey, forResultAt: index) as? Date
                  ?? item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            else { return nil }
            return RecentFile(
                path: path,
                contentType: query.value(ofAttribute: NSMetadataItemContentTypeKey, forResultAt: index) as? String,
                lastUsed: lastUsed,
                size: (query.value(ofAttribute: "kMDItemLogicalSize", forResultAt: index) as? NSNumber)?.int64Value,
                home: home
            )
        }
    }
}

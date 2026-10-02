import Foundation

/// A source-interest lifetime, not a Runtime callback. Cancelling detaches the
/// task handler under lock and invokes it outside every backend/core lock.
final class RasterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var handler: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func install(_ handler: @escaping () -> Void) {
        lock.lock(); let cancel = stopped
        if !cancel { self.handler = handler }; lock.unlock()
        if cancel { handler() }
    }
    func clear() { lock.lock(); handler = nil; lock.unlock() }
    func cancel() {
        lock.lock(); stopped = true; let callback = handler; handler = nil; lock.unlock()
        callback?()
    }
}

/// Workers keep a descriptor, never a queued encoded Data closure. Complete
/// resolvers still verify through their existing bytes/url path. Remote inputs
/// spool to a bounded temporary file and are reused for metadata and decode.
final class RasterInput: @unchecked Sendable {
    static var httpCacheUsage: [String: Int] { RasterDownload.cacheUsage }
    let url: URL
    let encodedBytes: Int
    private let temporary: Bool
    private init(url: URL, encodedBytes: Int, temporary: Bool) {
        self.url = url; self.encodedBytes = encodedBytes; self.temporary = temporary
    }
    deinit { if temporary { try? FileManager.default.removeItem(at: url) } }
    static func open(_ name: String, resolver: AssetResolver, cancellation: RasterCancellation = RasterCancellation()) throws -> RasterInput {
        guard !cancellation.isCancelled else { throw URLError(.cancelled) }
        // The app's own file (LLP 1069.002 D7): a picked photo's preview.
        if name.hasPrefix("app:/") {
            guard let url = AppFiles.url(name) else { throw RasterFailure.decode }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let count = values.fileSize,
                  count > 0, count <= RasterMetadata.encodedLimit else { throw RasterFailure.encodedLimit }
            return RasterInput(url: url, encodedBytes: count, temporary: false)
        }
        if let url = URL(string: name), let scheme = url.scheme {
            guard scheme == "https" || scheme == "http" else { throw RasterFailure.decode }
            let download = try RasterDownload(url: url)
            let (file, count) = try download.run(cancellation)
            return RasterInput(url: file, encodedBytes: count, temporary: true)
        }
        guard let url = resolver.url(name, maximumBytes: RasterMetadata.encodedLimit) else { throw RasterFailure.decode }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize,
              count > 0, count <= RasterMetadata.encodedLimit else { throw RasterFailure.encodedLimit }
        return RasterInput(url: url, encodedBytes: count, temporary: false)
    }
    func metadata() throws -> RasterMetadata {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let prefix = try file.read(upToCount: RasterMetadata.headerLimit) ?? Data()
        return try RasterMetadata.read(prefix: prefix, encodedBytes: encodedBytes)
    }
    func bytes() throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // A changed file cannot make readToEnd allocate an unbounded buffer.
        guard try file.seekToEnd() == encodedBytes else { throw RasterFailure.encodedLimit }
        try file.seek(toOffset: 0)
        let bytes = try file.read(upToCount: encodedBytes) ?? Data()
        guard bytes.count == encodedBytes else { throw RasterFailure.decode }
        return bytes
    }
}

private final class RasterDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Encoded HTTP responses are separate from the decoded-raster ledger.
    // Keep them across process restarts without another in-memory image cache.
    private static let responseCache = URLCache(memoryCapacity: 0, diskCapacity: 64 * 1024 * 1024,
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("exact-raster-http", isDirectory: true))
    static var cacheUsage: [String: Int] {
        ["memoryBytes": responseCache.currentMemoryUsage, "memoryCapacity": responseCache.memoryCapacity,
         "diskBytes": responseCache.currentDiskUsage, "diskCapacity": responseCache.diskCapacity]
    }
    private let url: URL
    private let destination: URL
    private let file: FileHandle
    private let done = DispatchSemaphore(value: 0)
    private var count = 0
    private var failure: Error?
    /// A download's file goes when its input does (`RasterInput.deinit`),
    /// which a process that is killed never reaches: every launch left one
    /// behind. Each process downloads into its own folder, named by its pid
    /// (the Mac's tmp is shared by every app); before its first, the folders
    /// of processes no longer running go.
    private static let folder: URL = {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exact-raster-downloads", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let pid = pid_t(name), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? fm.removeItem(at: root.appendingPathComponent(name)) }
        }
        #if os(iOS)
        // The loose `exact-raster-<uuid>` files an earlier build left (an iOS
        // app's tmp is its own).
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
        where name.hasPrefix("exact-raster-") && UUID(uuidString: String(name.dropFirst(13))) != nil {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
        #endif
        let mine = root.appendingPathComponent(String(getpid()), isDirectory: true)
        try? fm.createDirectory(at: mine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return mine
    }()
    init(url: URL) throws {
        self.url = url
        destination = Self.folder.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RasterFailure.decode }
        file = try FileHandle(forWritingTo: destination)
        super.init()
    }
    func run(_ cancellation: RasterCancellation) throws -> (URL, Int) {
        // RFC 5861: a stored response within its stale-while-revalidate window
        // is shown now and refreshed behind, as a browser does. URLCache keeps
        // the bytes but knows only max-age, so a launch after ten minutes
        // waited on the network for an image it already had.
        if let (data, stale) = Self.storedWithinWindow(url) {
            try file.write(contentsOf: data); count = data.count
            try? file.close()
            if stale { Self.revalidate(url) }
            return (destination, count)
        }
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = Self.responseCache; configuration.requestCachePolicy = .useProtocolCachePolicy
        // Switching cache policy must not add ambient cookies or credentials.
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: url)
        cancellation.install { task.cancel() }
        task.resume()
        done.wait() // bounded URLSession resource timeout, on a process worker
        cancellation.clear()
        session.finishTasksAndInvalidate()
        try? file.close()
        if let failure { try? FileManager.default.removeItem(at: destination); throw failure }
        guard count > 0 else { try? FileManager.default.removeItem(at: destination); throw RasterFailure.decode }
        return (destination, count)
    }
    /// The stored body for `url` if it may be shown now: fresh, or stale
    /// within `stale-while-revalidate` (then `stale` is true).
    private static func storedWithinWindow(_ url: URL) -> (Data, Bool)? {
        guard let stored = responseCache.cachedResponse(for: URLRequest(url: url)),
              let http = stored.response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !stored.data.isEmpty, stored.data.count <= RasterMetadata.encodedLimit else { return nil }
        let directives = (http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func seconds(_ name: String) -> Double? {
            directives.first { $0.hasPrefix(name + "=") }.flatMap { Double($0.dropFirst(name.count + 1)) }
        }
        guard !directives.contains("no-store"), !directives.contains("no-cache"),
              let maxAge = seconds("max-age") else { return nil }
        let window = seconds("stale-while-revalidate") ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = http.value(forHTTPHeaderField: "Date").flatMap(formatter.date(from:)) else { return nil }
        let age = Date().timeIntervalSince(date) + (http.value(forHTTPHeaderField: "Age").flatMap(Double.init) ?? 0)
        guard age <= maxAge + window else { return nil }
        return (stored.data, age > maxAge)
    }

    /// Refresh the stored response for `url` behind the image already shown.
    private static func revalidate(_ url: URL) {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = responseCache; configuration.requestCachePolicy = .reloadRevalidatingCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        session.dataTask(with: url) { _, _, _ in session.finishTasksAndInvalidate() }.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= RasterMetadata.encodedLimit,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            failure = RasterFailure.encodedLimit; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, data.count <= RasterMetadata.encodedLimit - count else {
            failure = RasterFailure.encodedLimit; dataTask.cancel(); return
        }
        do { try file.write(contentsOf: data); count += data.count }
        catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        failure = failure ?? error; done.signal()
    }
}

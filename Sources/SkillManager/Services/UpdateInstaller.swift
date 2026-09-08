import AppKit
import Foundation

/// A release DMG attached at `mountPoint`, with the app bundle already verified
/// to exist inside it. Whoever receives one owns it: `await detach()` when done,
/// otherwise the volume outlives the app and the next update run stacks a second
/// copy on top of it.
struct MountedImage: Sendable {
    let dmg: URL
    let mountPoint: URL
    let appBundle: URL

    /// Detaches the image and deletes the downloaded DMG. Never throws — this
    /// runs on the cleanup path, where a failed detach must not mask the error
    /// that got us there.
    func detach() async {
        let result = try? await Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
        if result?.succeeded != true {
            // Busy volume (Finder indexing, a copy still draining): force it.
            _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        }
        try? FileManager.default.removeItem(at: dmg.deletingLastPathComponent())
    }
}

enum UpdateInstallError: LocalizedError {
    case downloadFailed(status: Int)
    case attachFailed(String)
    case noMountPoint
    case appBundleMissing(volume: String)
    case targetNotWritable(path: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let status):
            return "Downloading the update failed (HTTP \(status))."
        case .attachFailed(let output):
            return "Could not mount the update image: \(output.prefix(300))"
        case .noMountPoint:
            return "The update image mounted without a readable mount point."
        case .appBundleMissing(let volume):
            return "No SkillManager.app inside the update image (\(volume))."
        case .targetNotWritable(let path):
            return "No write access to \(path) — install the update manually."
        }
    }
}

/// Downloads a release DMG, unquarantines it and mounts it read-only. Stops at
/// "the new app bundle is visible on a mounted volume" — replacing the running
/// app is the caller's job.
struct UpdateInstaller {
    static let appBundleName = "SkillManager.app"

    let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    /// Download → unquarantine → mount, reporting download progress in 0...1.
    func prepare(
        dmgURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MountedImage {
        let dmg = try await download(from: dmgURL, progress: progress)
        await stripQuarantine(at: dmg)
        return try await mount(dmg: dmg)
    }

    /// Downloads into a temp directory this app owns and returns the DMG path.
    func download(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("SkillManager", forHTTPHeaderField: "User-Agent")

        // Own temp directory, so `detach()` can drop the whole thing afterwards.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillManagerUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = url.lastPathComponent.hasSuffix(".dmg") ? url.lastPathComponent : "update.dmg"
        let destination = directory.appendingPathComponent(name)

        do {
            let download = DMGDownload(
                configuration: configuration,
                destination: destination,
                onProgress: progress
            )
            return try await download.run(request: request)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Releases are ad-hoc signed (`codesign --sign -`), so a downloaded DMG
    /// carries `com.apple.quarantine` and the replaced app would be blocked by
    /// Gatekeeper. A non-zero exit only means the attribute was not set.
    func stripQuarantine(at url: URL) async {
        _ = try? await Shell.run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", url.path])
    }

    /// Attaches the DMG read-only under /tmp and verifies the app bundle is there.
    func mount(dmg: URL) async throws -> MountedImage {
        let result = try await Shell.run("/usr/bin/hdiutil", [
            "attach", dmg.path,
            "-nobrowse",
            "-readonly",
            "-mountrandom", "/tmp",
            "-plist"
        ])
        guard result.succeeded else {
            throw UpdateInstallError.attachFailed(result.combinedOutput)
        }
        guard let mountPoint = Self.mountPoint(fromPlist: result.stdout) else {
            throw UpdateInstallError.noMountPoint
        }

        let image = MountedImage(
            dmg: dmg,
            mountPoint: mountPoint,
            appBundle: mountPoint.appendingPathComponent(Self.appBundleName)
        )
        guard FileManager.default.fileExists(atPath: image.appBundle.path) else {
            await image.detach()
            throw UpdateInstallError.appBundleMissing(volume: mountPoint.path)
        }
        return image
    }

    /// Pulls the first `mount-point` out of `hdiutil attach -plist` output.
    /// Parsing the plist beats splitting the tab-separated default output, which
    /// also lists partition entries that have no mount point at all.
    static func mountPoint(fromPlist stdout: String) -> URL? {
        // Verification chatter can precede the plist; start at the XML header.
        guard let start = stdout.range(of: "<?xml") else { return nil }
        let data = Data(stdout[start.lowerBound...].utf8)

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else {
            return nil
        }

        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
        guard let path = mountPoints.first(where: { !$0.isEmpty }) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Install

    /// The bundle the running app lives in — whatever path that is, so a build
    /// in `./build` updates itself the same way an installed copy does.
    /// Symlinks are resolved because the writability probe and `replaceItemAt`
    /// both act on the real parent directory, not on the link.
    static var installTarget: URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    /// `replaceItemAt` rewrites a directory entry in the *parent*, so the parent
    /// is what has to be writable — the bundle's own mode says nothing. Catches
    /// both `/Applications` owned by another admin and an app running
    /// translocated from a read-only image.
    static func canInstall(at target: URL = installTarget) -> Bool {
        FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
    }

    /// Copies the new bundle next to the running one and swaps the two.
    /// Returns the path the app now lives at, ready to be relaunched.
    ///
    /// Replacing the bundle out from under the running process is safe: the old
    /// inode stays alive until this process exits, so the executing binary and
    /// any not-yet-loaded resources remain readable through it.
    @discardableResult
    func install(_ image: MountedImage, to target: URL = installTarget) async throws -> URL {
        guard Self.canInstall(at: target) else {
            throw UpdateInstallError.targetNotWritable(
                path: target.deletingLastPathComponent().path
            )
        }

        let fileManager = FileManager.default

        // `.itemReplacementDirectory` lands on the same volume as the target,
        // which is exactly what `replaceItemAt` requires — a copy staged in
        // /tmp would cross volumes and fall back to a non-atomic move.
        let staging = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: target,
            create: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(target.lastPathComponent)
        try fileManager.copyItem(at: image.appBundle, to: staged)
        // The DMG was unquarantined before it was mounted, but a release built
        // elsewhere can carry the attribute on the bundle itself.
        await stripQuarantine(at: staged)

        // Either the swap happens or the original bundle is still there: no
        // window where the app is half-replaced.
        let replaced = try fileManager.replaceItemAt(target, withItemAt: staged)
        return replaced ?? target
    }

    /// Starts the replaced bundle and quits this process.
    ///
    /// The new instance is forced: without it LaunchServices sees a running app
    /// with the same bundle id and just reactivates *this* one, leaving the user
    /// on the old version with no sign anything happened.
    @MainActor
    static func relaunch(at bundle: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        NSApp.terminate(nil)
    }

    /// Fallback when the app sits somewhere we may not write: show the mounted
    /// volume so the user can drag the app across themselves. The image is
    /// deliberately left attached — detaching it would pull the file out of the
    /// Finder window we just opened.
    @MainActor
    static func revealForManualInstall(_ image: MountedImage) {
        NSWorkspace.shared.activateFileViewerSelecting([image.appBundle])
    }
}

/// One download, driven by a session that owns this object as its delegate.
///
/// The async `URLSession.download(for:delegate:)` only routes
/// `URLSessionTaskDelegate` messages to its per-task delegate, so
/// `didWriteData` — the one callback that carries progress — never arrives that
/// way. A session-level delegate does receive it, at the price of running the
/// continuation by hand.
private final class DMGDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void

    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReportedPercent = -1

    init(
        configuration: URLSessionConfiguration,
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func run(request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    /// Resumes the continuation at most once and tears the session down; the
    /// session holds a strong reference to this delegate until it is invalidated.
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        session.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }

    /// Reports only on whole-percent changes — this fires per chunk, and a
    /// main-actor hop per chunk would swamp the UI for no visible gain.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let percent = Int(fraction * 100)

        lock.lock()
        let changed = percent != lastReportedPercent
        if changed { lastReportedPercent = percent }
        lock.unlock()

        if changed { onProgress(fraction) }
    }

    /// `location` is deleted the moment this returns, so the move happens here
    /// rather than back on the caller's side.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            finish(.failure(UpdateInstallError.downloadFailed(status: http.statusCode)))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // On success this lands after `didFinishDownloadingTo` and no-ops.
        guard let error else { return }
        finish(.failure(error))
    }
}

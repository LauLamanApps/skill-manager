import Foundation
import SwiftUI

enum UpdateState {
    case idle
    case checking
    case upToDate
    case available(Release)
    case downloading(Double)
    case readyToInstall
    case installing
    /// The app cannot be replaced in place; the update is open in Finder instead.
    case manualInstall(volume: String)
    case failed(String)
}

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    @AppStorage("lastUpdateCheck") private var lastUpdateCheckRaw: Double = 0

    private let checker: UpdateChecker
    private let installer: UpdateInstaller

    /// DMG asset of the release the last check found, kept so the download does
    /// not have to hit the API again.
    private var pendingDMGURL: URL?

    /// Set once the DMG is downloaded and mounted; `installUpdate()` copies the
    /// app bundle out of this and detaches it.
    private(set) var mountedUpdate: MountedImage?

    private var automaticCheckTask: Task<Void, Never>?

    init(checker: UpdateChecker = UpdateChecker(), installer: UpdateInstaller = UpdateInstaller()) {
        self.checker = checker
        self.installer = installer
    }

    var lastUpdateCheck: Date? {
        lastUpdateCheckRaw > 0 ? Date(timeIntervalSince1970: lastUpdateCheckRaw) : nil
    }

    func checkIfDue() async {
        let needsCheck: Bool
        if let lastCheck = lastUpdateCheck {
            let hoursSinceCheck = Date().timeIntervalSince(lastCheck) / 3600
            needsCheck = hoursSinceCheck >= 24
        } else {
            needsCheck = true
        }

        if needsCheck {
            await checkForUpdates()
        }
    }

    func startAutomaticChecks() {
        stopAutomaticChecks()

        // Initial check on launch.
        Task {
            await checkIfDue()
        }

        // Repeat every 24 hours.
        automaticCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000)
                if !Task.isCancelled {
                    await checkIfDue()
                }
            }
        }
    }

    func stopAutomaticChecks() {
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
    }

    func checkForUpdates() async {
        // A previous run may have left a volume attached; it is stale now.
        await discardMountedUpdate()

        state = .checking
        pendingDMGURL = nil

        switch await checker.check() {
        case .upToDate:
            state = .upToDate
        case .available(let release, let dmgURL):
            pendingDMGURL = dmgURL
            state = .available(release)
        case .failed(let error):
            state = .failed(error.localizedDescription)
        }
        lastUpdateCheckRaw = Date().timeIntervalSince1970
    }

    /// Downloads the release DMG, strips its quarantine flag and mounts it.
    /// Ends at `.readyToInstall` with `mountedUpdate` set.
    func downloadUpdate() {
        guard let dmgURL = pendingDMGURL else { return }

        state = .downloading(0)
        Task {
            do {
                let image = try await installer.prepare(dmgURL: dmgURL) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                mountedUpdate = image
                state = .readyToInstall
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Replaces the running bundle with the downloaded one and restarts into it.
    ///
    /// When the app lives somewhere this process may not write, nothing is
    /// touched at all: the mounted volume is revealed in Finder so the user can
    /// drag the new app into place. That image stays attached on purpose —
    /// it is the thing the user is about to copy from.
    func installUpdate() {
        guard let image = mountedUpdate else { return }

        guard UpdateInstaller.canInstall() else {
            mountedUpdate = nil
            UpdateInstaller.revealForManualInstall(image)
            state = .manualInstall(volume: image.mountPoint.path)
            return
        }

        state = .installing
        Task {
            do {
                let replaced = try await installer.install(image)
                // Past the swap the volume has served its purpose, and the new
                // instance should not inherit a stale mount.
                mountedUpdate = nil
                await image.detach()
                try await UpdateInstaller.relaunch(at: replaced)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func discardMountedUpdate() async {
        guard let image = mountedUpdate else { return }
        mountedUpdate = nil
        await image.detach()
    }
}

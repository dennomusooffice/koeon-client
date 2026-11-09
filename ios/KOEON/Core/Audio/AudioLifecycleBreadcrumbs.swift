import Foundation

private let audioBreadcrumbMaximumEvents = 64

struct AudioLifecycleBreadcrumb: Codable, Equatable, Sendable {
    let timestamp: Date
    let platform: String
    let build: String
    let generationToken: String?
    let role: String
    let stage: String
    let actorClass: String
    let resultClass: String
}

final class AudioLifecycleBreadcrumbStore: @unchecked Sendable {
    static let shared = AudioLifecycleBreadcrumbStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    // Preserve diagnostic history across upgrades; this storage key is not a transport.
    private let eventsKey = "batv1.crashBreadcrumbs.v1"
    private let runKnownKey = "batv1.runKnown"
    private let lastLifecycleKey = "batv1.lastObservedLifecycle.v1"
    private var events: [AudioLifecycleBreadcrumb] = []
    private struct PollKey: Equatable {
        let generation: String
        let stage: String
    }
    // Exact IDs are used only in bounded RAM, never added to persisted evidence.
    private var recordedPolls: [PollKey] = []
    private var build = "unknown"
    // A lifecycle marker is not an OS termination report. Keep this legacy
    // diagnostic unknown instead of inferring a crash or clean exit from it.
    let previousRunTermination = "UNKNOWN"
    private(set) var previousRunLastLifecycleState = "UNKNOWN"
    private var initialized = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func startRun(build: String) {
        lock.withLock {
            guard !initialized else { return }
            self.build = String(build.prefix(64))
            if defaults.bool(forKey: runKnownKey),
               let previous = defaults.string(forKey: lastLifecycleKey),
               ["STARTING", "ACTIVE", "INACTIVE", "BACKGROUND", "UNKNOWN"].contains(previous) {
                previousRunLastLifecycleState = previous
            }
            if let data = defaults.data(forKey: eventsKey),
               let saved = try? JSONDecoder().decode([AudioLifecycleBreadcrumb].self, from: data) {
                events = Array(saved.suffix(audioBreadcrumbMaximumEvents))
            }
            initialized = true
            defaults.set(true, forKey: runKnownKey)
            defaults.removeObject(forKey: "batv1.cleanExit")
            defaults.set("STARTING", forKey: lastLifecycleKey)
        }
        record(role: "APP", stage: "APP_START")
    }

    func record(
        role: String,
        stage: String,
        generationId: String? = nil,
        actorClass: String = Thread.isMainThread ? "MAIN_ACTOR" : "BACKGROUND",
        resultClass: String = "OK"
    ) {
        lock.withLock {
            guard initialized else { return }
            if role == "RX", resultClass == "OK", let generationId,
               stage == "RX_SUBSCRIBE_BEGIN" || stage == "RX_SUBSCRIBE_END" {
                let key = PollKey(generation: generationId, stage: stage)
                guard !recordedPolls.contains(key) else { return }
                if recordedPolls.count >= audioBreadcrumbMaximumEvents { recordedPolls.removeFirst() }
                recordedPolls.append(key)
            }
            events.append(AudioLifecycleBreadcrumb(
                timestamp: Date(),
                platform: "ios",
                build: build,
                generationToken: generationId.map { String($0.prefix(8)) },
                role: String(role.prefix(8)),
                stage: String(stage.prefix(64)),
                actorClass: String(actorClass.prefix(32)),
                resultClass: String(resultClass.prefix(64))
            ))
            if events.count > audioBreadcrumbMaximumEvents {
                events.removeFirst(events.count - audioBreadcrumbMaximumEvents)
            }
            if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: eventsKey) }
        }
    }

    func recordAppLifecycle(_ phase: String) {
        let state: String
        let stage: String
        switch phase {
        case "active": (state, stage) = ("ACTIVE", "APP_RESUME")
        case "inactive": (state, stage) = ("INACTIVE", "APP_INACTIVE")
        case "background": (state, stage) = ("BACKGROUND", "APP_BACKGROUND")
        default: (state, stage) = ("UNKNOWN", "APP_LIFECYCLE_UNKNOWN")
        }
        lock.withLock {
            guard initialized else { return }
            defaults.set(state, forKey: lastLifecycleKey)
        }
        record(role: "APP", stage: stage)
    }

    func snapshot() -> [AudioLifecycleBreadcrumb] { lock.withLock { events } }
}


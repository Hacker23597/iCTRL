import Foundation
import Network
import dnssd

/// What a nearby (peer-to-peer Wi-Fi) client sees of this device: a stable
/// random identifier and a display name.
///
/// The identifier is generated once and kept in the app's sandbox next to the
/// pairing keys, so clients can recognise the same device although its AWDL
/// address changes. It is random — not derived from any hardware identifier.
///
/// iOS does not give apps the user-assigned device name, so the default name is
/// the hardware model plus the first four characters of the identifier; a
/// paired client can replace it (`config{device_name}`).
enum NearbyIdentity {
    private struct Stored: Codable {
        var id: String
        var name: String?
    }

    private static let lock = NSLock()
    private static var cached: Stored?

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("iCTRL", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nearby_identity.json")
    }

    private static func load() -> Stored {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.id.count == 32 {
            cached = stored
            return stored
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = Stored(id: bytes.map { String(format: "%02x", $0) }.joined(), name: nil)
        save(fresh)
        cached = fresh
        return fresh
    }

    private static func save(_ stored: Stored) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 32 lowercase hex characters, stable for this installation.
    static var deviceID: String { load().id }

    /// The name advertised to nearby clients.
    static var name: String { load().name ?? defaultName }

    /// Whether `name` was set by a client rather than generated.
    static var hasCustomName: Bool { load().name != nil }

    static var defaultName: String { "\(modelName) (\(deviceID.prefix(4)))" }

    /// Longest name accepted: a DNS-SD instance name is one DNS label (63 bytes).
    static let maxNameBytes = 63

    /// Set a custom name; nil or blank restores the default. Returns the name in
    /// effect, or nil when the new name is too long.
    @discardableResult
    static func setName(_ newName: String?) -> String? {
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.utf8.count <= maxNameBytes else { return nil }
        var stored = load()
        stored.name = trimmed.isEmpty ? nil : trimmed
        lock.lock()
        cached = stored
        lock.unlock()
        save(stored)
        return stored.name ?? defaultName
    }

    /// Marketing name of the hardware, e.g. "iPhone 11"; the generic family
    /// name for identifiers this table does not know yet.
    static var modelName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var raw = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &raw, &size, nil, 0)
        let machine = String(cString: raw)
        if let known = models[machine] { return known }
        if machine.hasPrefix("iPad") { return "iPad" }
        if machine.hasPrefix("iPod") { return "iPod touch" }
        return "iPhone"
    }

    private static let models: [String: String] = [
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,4": "iPhone Air",
    ]
}

/// Advertises the nearby listener over Bonjour on the AWDL interface only.
///
/// The service is registered with the *specific* interface index of `awdl0`.
/// Neither interface 0 nor `kDNSServiceInterfaceIndexP2P` may be used: both
/// also advertise on Wi-Fi/Ethernet (dns_sd.h maps P2P on Register to "any
/// interface, including P2P"), which would announce the device to the whole
/// LAN. When `awdl0` is absent (Wi-Fi off) nothing is registered; the
/// advertiser checks again periodically.
final class NearbyAdvertiser {
    private let port: UInt16
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private var ref: DNSServiceRef?
    private var retry: DispatchSourceTimer?
    private var stopped = true

    /// Called on `queue` whenever advertising starts or stops being active.
    var onChange: ((Bool) -> Void)?
    private(set) var isAdvertising = false {
        didSet { if isAdvertising != oldValue { onChange?(isAdvertising) } }
    }

    static let serviceType = "_ictrl._tcp"
    private static let retryInterval: TimeInterval = 30

    init(port: UInt16, queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.port = port
        self.queue = queue
        self.log = log
    }

    func start() {
        queue.async {
            self.stopped = false
            self.register()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.retry?.cancel()
            self.retry = nil
            self.deregister()
        }
    }

    /// Re-register under the current `NearbyIdentity.name`.
    func refreshName() {
        queue.async {
            guard !self.stopped else { return }
            self.deregister()
            self.register()
        }
    }

    // MARK: - Registration (on `queue`)

    private func register() {
        guard !stopped, ref == nil else { return }
        let index = if_nametoindex("awdl0")
        guard index != 0 else {
            log("📡 Nearby: awdl0 is not available (Wi-Fi off?) — not advertising; checking again in \(Int(Self.retryInterval))s")
            scheduleRetry()
            return
        }

        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        setTXT(&txt, "v", String(RPCMethodRegistry.protocolVersion))
        setTXT(&txt, "id", NearbyIdentity.deviceID)

        let name = NearbyIdentity.name
        var newRef: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = DNSServiceRegister(
            &newRef, DNSServiceFlags(kDNSServiceFlagsIncludeAWDL), index,
            name, Self.serviceType, nil, nil, port.bigEndian,
            TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
            { _, _, errorCode, registeredName, _, _, context in
                guard let context else { return }
                let me = Unmanaged<NearbyAdvertiser>.fromOpaque(context).takeUnretainedValue()
                me.registrationCallback(errorCode, registeredName.map { String(cString: $0) })
            }, context)
        guard err == kDNSServiceErr_NoError, let newRef else {
            log("📡 Nearby: DNSServiceRegister failed (\(err))\(Self.hint(for: err)); checking again in \(Int(Self.retryInterval))s")
            scheduleRetry()
            return
        }
        DNSServiceSetDispatchQueue(newRef, queue)
        ref = newRef
        log("📡 Nearby: registering \"\(name)\" on awdl0 (index \(index)), port \(port)")
    }

    private func registrationCallback(_ err: DNSServiceErrorType, _ registeredName: String?) {
        if err == kDNSServiceErr_NoError {
            log("📡 Nearby: advertised as \"\(registeredName ?? "?")\" on awdl0 only")
            isAdvertising = true
        } else {
            log("📡 Nearby: registration failed (\(err))\(Self.hint(for: err)); checking again in \(Int(Self.retryInterval))s")
            deregister()
            scheduleRetry()
        }
    }

    private func deregister() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
        isAdvertising = false
    }

    private func scheduleRetry() {
        guard !stopped, retry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.retryInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.register()
        }
        retry = timer
        timer.resume()
    }

    private func setTXT(_ txt: inout TXTRecordRef, _ key: String, _ value: String) {
        let bytes = Array(value.utf8)
        TXTRecordSetValue(&txt, key, UInt8(bytes.count), bytes)
    }

    private static func hint(for err: DNSServiceErrorType) -> String {
        switch Int(err) {
        case Int(kDNSServiceErr_NoAuth), Int(kDNSServiceErr_PolicyDenied):
            return " — Local Network access denied, or the service type is missing from NSBonjourServices"
        default:
            return ""
        }
    }
}

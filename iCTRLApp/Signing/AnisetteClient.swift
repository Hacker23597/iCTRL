import Foundation

/// Fetches anisette data from an external provider.
///
/// Anisette is the set of device-fingerprint headers Apple's authentication
/// servers require before they will accept an Apple ID login. `AnisetteProbe`
/// established that iOS cannot produce these locally — there is no linkable ADI
/// library, only an entitled XPC service — so a provider outside the device is
/// the only option. That is a real trust dependency, not an implementation
/// detail, which is why this type surfaces which server it used rather than
/// hiding it behind a default.
///
/// The provider sees the fingerprint your Apple ID logs in under. Providers that
/// hand the same machine identifier to many users have had accounts locked, so
/// the honest framing for the UI is: pick one you trust, or run your own.
enum AnisetteClient {

    /// One fetch's worth of headers, in the shape the GSA handshake wants.
    struct AnisetteData: Equatable {
        var machineID: String              // X-Apple-I-MD-M
        var oneTimePassword: String        // X-Apple-I-MD
        var routingInfo: String            // X-Apple-I-MD-RINFO
        var localUserID: String            // X-Apple-I-MD-LU
        var deviceUniqueIdentifier: String // X-Mme-Device-Id
        var deviceSerialNumber: String     // X-Apple-I-SRL-NO
        var date: Date
        var locale: Locale
        var timeZone: TimeZone
    }

    enum AnisetteError: LocalizedError {
        case http(Int)
        case malformed(String)
        case noServerConfigured

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return "The anisette server returned HTTP \(code)"
            case .malformed(let what):
                return "The anisette server's reply made no sense: \(what)"
            case .noServerConfigured:
                return "No anisette server is set. Signing in to an Apple ID needs one — iOS can't generate this itself."
            }
        }
    }

    /// Providers answer with slightly different key spellings depending on which
    /// implementation they run, so each field is looked up under every name it
    /// is known by. Failing on a cosmetic key difference would look to the user
    /// like the server being down.
    private static func string(_ dict: [String: Any], _ names: [String]) -> String? {
        for name in names {
            if let value = dict[name] as? String { return value }
        }
        return nil
    }

    /// Fetches anisette from `server`.
    ///
    /// Deliberately takes the server as a parameter with no default: there is no
    /// safe default here, and picking one silently would hide the trust decision
    /// from the person making it.
    static func fetch(from server: URL) async throws -> AnisetteData {
        ictrlLog("Fetching anisette from \(server.host ?? server.absoluteString)")

        var request = URLRequest(url: server)
        request.timeoutInterval = 30
        request.setValue("iCTRL", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnisetteError.http(http.statusCode)
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.malformed("not JSON")
        }

        guard let machineID = string(dict, ["X-Apple-I-MD-M", "machineID", "md-m"]),
              let otp = string(dict, ["X-Apple-I-MD", "oneTimePassword", "md"])
        else {
            // These two are the fingerprint proper; without them the reply is
            // not anisette regardless of what else it contains.
            throw AnisetteError.malformed("missing the machine identifier or one-time password")
        }

        let anisette = AnisetteData(
            machineID: machineID,
            oneTimePassword: otp,
            routingInfo: string(dict, ["X-Apple-I-MD-RINFO", "routingInfo", "md-rinfo"]) ?? "17106176",
            localUserID: string(dict, ["X-Apple-I-MD-LU", "localUserID", "md-lu"]) ?? "",
            deviceUniqueIdentifier: string(dict, ["X-Mme-Device-Id", "deviceUniqueIdentifier", "device-id"]) ?? "",
            deviceSerialNumber: string(dict, ["X-Apple-I-SRL-NO", "deviceSerialNumber", "serial"]) ?? "0",
            date: Date(),
            locale: Locale.current,
            timeZone: TimeZone.current
        )

        ictrlLog("Anisette fetched — machineID \(machineID.prefix(8))…")
        return anisette
    }

    // MARK: - Server selection

    /// The chosen provider, remembered between launches.
    ///
    /// No value ships as a default. iCTRL shouldn't quietly route someone's
    /// Apple ID login through a server they never chose.
    private static let serverKey = "anisetteServerURL"

    static var configuredServer: URL? {
        get {
            guard let s = UserDefaults.standard.string(forKey: serverKey) else { return nil }
            return URL(string: s)
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: serverKey)
        }
    }

    static func fetchFromConfiguredServer() async throws -> AnisetteData {
        guard let server = configuredServer else { throw AnisetteError.noServerConfigured }
        return try await fetch(from: server)
    }
}

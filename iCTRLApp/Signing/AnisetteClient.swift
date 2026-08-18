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

    /// Servers answer in one of two shapes: the header spellings Apple uses
    /// (`X-Apple-I-MD-M`) or AltSign's camel-cased names (`machineID`). Both are
    /// accepted, since which one you get depends on the provider's
    /// implementation rather than on anything the user chose.
    private static let aliases: [String: [String]] = [
        "machineID":              ["machineID", "X-Apple-I-MD-M"],
        "oneTimePassword":        ["oneTimePassword", "X-Apple-I-MD"],
        "localUserID":            ["localUserID", "X-Apple-I-MD-LU"],
        "routingInfo":            ["routingInfo", "X-Apple-I-MD-RINFO"],
        "deviceUniqueIdentifier": ["deviceUniqueIdentifier", "X-Mme-Device-Id"],
        "deviceSerialNumber":     ["deviceSerialNumber", "X-Apple-I-SRL-NO"],
        "deviceDescription":      ["deviceDescription", "X-Mme-Client-Info"],
        "date":                   ["date", "X-Apple-I-Client-Time"],
        "locale":                 ["locale", "X-Apple-Locale"],
        "timeZone":               ["timeZone", "X-Apple-I-TimeZone"],
    ]

    /// Fields a server may legitimately omit, with what to use instead.
    ///
    /// `ALTAnisetteData.initWithJSON:` returns nil unless all ten keys are
    /// present, which is stricter than servers actually behave — several send
    /// only the fingerprint proper and leave the client to fill in its own
    /// locale and clock. Failing the login over a missing time zone would
    /// report "server broken" for something that isn't.
    private static func defaultValue(for key: String) -> String? {
        switch key {
        case "deviceDescription":
            return "<MacBookPro13,2> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        case "date":
            return ISO8601DateFormatter().string(from: Date())
        case "locale":
            return Locale.current.identifier
        case "timeZone":
            return TimeZone.current.abbreviation() ?? "UTC"
        default:
            // The fingerprint fields have no sensible stand-in; a made-up
            // machine identifier would be rejected by Apple anyway.
            return nil
        }
    }

    /// Fetches anisette from `server` and returns it in AltSign's shape.
    ///
    /// Deliberately takes the server as a parameter with no default: there is no
    /// safe default here, and picking one silently would hide the trust decision
    /// from the person making it.
    static func fetch(from server: URL) async throws -> ALTAnisetteData {
        ictrlLog("Fetching anisette from \(server.host ?? server.absoluteString)")

        var request = URLRequest(url: server)
        request.timeoutInterval = 30
        request.setValue("iCTRL", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnisetteError.http(http.statusCode)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.malformed("not JSON")
        }

        // Some servers nest the payload; unwrap before looking for fields so a
        // wrapper key doesn't read as "nothing here".
        let body = (raw["result"] as? [String: Any]) ?? raw

        var normalized: [String: String] = [:]
        var missing: [String] = []
        for (key, names) in aliases {
            if let value = names.compactMap({ body[$0] }).first {
                normalized[key] = "\(value)"
            } else if let fallback = defaultValue(for: key) {
                normalized[key] = fallback
            } else {
                missing.append(key)
            }
        }

        guard missing.isEmpty else {
            throw AnisetteError.malformed("missing \(missing.sorted().joined(separator: ", "))")
        }
        guard let anisette = ALTAnisetteData(json: normalized) else {
            throw AnisetteError.malformed("AltSign rejected the fields")
        }

        ictrlLog("Anisette fetched — machineID \(normalized["machineID"]?.prefix(8) ?? "?")…")
        return anisette
    }

    // MARK: - Server selection

    /// A provider the user can pick.
    struct Server: Codable, Equatable, Identifiable {
        var name: String
        var address: String
        var id: String { address }
    }

    /// Where SideStore publishes the community server list, and the default this
    /// falls back to.
    ///
    /// Using SideStore's list is the pragmatic choice — these are the servers
    /// that exist, they are already the ones SideStore users authenticate
    /// through, and the list is maintained. It is still a third party holding
    /// the fingerprint your Apple ID logs in under, so the choice stays visible
    /// and changeable rather than being hidden behind a constant.
    static let serverListURL = URL(string: "https://servers.sidestore.io/servers.json")!

    /// Used until the list loads or if it can't be reached. SideStore's own
    /// server rather than a community one: it's the likeliest to be up, and
    /// picking someone's personal server as a silent default would be worse.
    static let fallbackServer = Server(name: "SideStore", address: "https://ani.sidestore.io")

    private static let serverKey = "anisetteServerURL"

    /// The chosen provider. Defaults to `fallbackServer` so signing works out of
    /// the box; the UI shows which one is in use and lets it be changed.
    static var configuredServer: URL? {
        get {
            if let s = UserDefaults.standard.string(forKey: serverKey), let url = URL(string: s) {
                return url
            }
            return URL(string: fallbackServer.address)
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: serverKey)
        }
    }

    /// True once the user has picked deliberately, so the UI can say whether it
    /// is using a default or their choice.
    static var hasExplicitServer: Bool {
        UserDefaults.standard.string(forKey: serverKey) != nil
    }

    /// Fetches the published server list.
    ///
    /// Failure is not fatal — `fallbackServer` still works — so this returns
    /// what it has rather than throwing the whole signing run away.
    static func fetchServerList() async -> [Server] {
        var request = URLRequest(url: serverListURL)
        request.timeoutInterval = 20
        request.setValue("iCTRL", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["servers"] as? [[String: Any]]
        else {
            ictrlLog("Couldn't fetch the anisette server list; using \(fallbackServer.name)")
            return [fallbackServer]
        }

        let servers = entries.compactMap { entry -> Server? in
            guard let name = entry["name"] as? String,
                  let address = entry["address"] as? String,
                  // Plain-HTTP entries appear in the list; sending a login
                  // fingerprint over one is worse than the choice being smaller.
                  address.hasPrefix("https://")
            else { return nil }
            return Server(name: name, address: address)
        }

        ictrlLog("Fetched \(servers.count) anisette servers")
        return servers.isEmpty ? [fallbackServer] : servers
    }

    static func fetchFromConfiguredServer() async throws -> ALTAnisetteData {
        guard let server = configuredServer else { throw AnisetteError.noServerConfigured }
        return try await fetch(from: server)
    }
}

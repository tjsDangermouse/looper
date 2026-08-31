import Foundation

/// Where raw OpenStreetMap path data comes from.
///
/// The abstraction is the point. Today it is the public Overpass API; the
/// public endpoint is a volunteer-run service and is not a production backend
/// for anybody's app, so the ability to swap in a commercial Overpass-compatible
/// endpoint later — by changing one configuration value and nothing else — is a
/// requirement of the design rather than a nicety. Nothing below this protocol
/// knows a hostname, and nothing above it knows the query language.
public protocol RoutingDataSource: Sendable {
    /// Highway ways intersecting the area, and every node those ways
    /// reference — including nodes outside the area, which is what stops a
    /// path being cut in half at the edge of the request.
    func fetchArea(_ bounds: GeographicBounds) async throws -> OSMData
}

public enum RoutingDataSourceError: Error, LocalizedError, Equatable {
    /// The device itself has no network. Nothing else will help.
    case offline
    /// The device has a network, but no configured OSM data provider would
    /// answer. A different failure from `offline` and it must stay different:
    /// telling somebody with four bars of signal to "connect to download it"
    /// sends them looking for a fault they do not have.
    case providerUnavailable(String)
    case httpStatus(Int)
    case rateLimited
    case malformedResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "There’s no connection, so walking paths for this area can’t be downloaded."
        case .providerUnavailable(let detail):
            return "The map data service isn’t responding, so walking paths for this area can’t be downloaded right now. \(detail)"
        case .httpStatus(let code):
            return "The map data service returned an error (\(code))."
        case .rateLimited:
            return "The map data service is busy. Try again in a moment."
        case .malformedResponse(let detail):
            return detail
        case .cancelled:
            return "The download was cancelled."
        }
    }

    /// A few words for a log line or for nesting inside another message.
    /// The full `errorDescription` is a sentence addressed to a walker, and a
    /// sentence quoted inside another sentence reads like a stack trace.
    var terseReason: String {
        switch self {
        case .offline: return "no network"
        case .providerUnavailable(let detail): return detail
        case .httpStatus(let code): return "HTTP \(code)"
        case .rateLimited: return "rate limited"
        case .malformedResponse(let detail): return detail
        case .cancelled: return "cancelled"
        }
    }

    /// Whether trying a different provider could plausibly help.
    var isWorthAnotherEndpoint: Bool {
        switch self {
        case .offline, .cancelled: return false
        case .providerUnavailable, .rateLimited, .malformedResponse: return true
        case .httpStatus(let code): return code >= 500 || code == 429
        }
    }
}

/// The HTTP seam. A protocol rather than `URLSession` directly so tests can
/// serve fixtures without a network, and so it is provable — not merely
/// assertable — that the on-device engine's only outbound traffic goes through
/// here, to the configured OSM data endpoint.
public protocol OverpassTransport: Sendable {
    func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int)
}

public struct URLSessionOverpassTransport: OverpassTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Looper/1.0 (on-device walking routes)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RoutingDataSourceError.malformedResponse("No HTTP response.") }
            return (data, http.statusCode)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                // Device-level: there is no network to use, so no other
                // provider is going to answer either.
                throw RoutingDataSourceError.offline
            case .cancelled:
                throw RoutingDataSourceError.cancelled
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
                 .secureConnectionFailed, .serverCertificateUntrusted, .resourceUnavailable,
                 .networkConnectionLost, .badServerResponse, .cannotLoadFromNetwork:
                // Per-connection: this provider did not answer. A public
                // Overpass instance that has heard enough from an address
                // stops answering rather than refusing politely, and that
                // arrives here.
                //
                // `networkConnectionLost` belongs on this side and it matters:
                // reading it as "the device is offline" aborts the search for
                // a working provider on the first host that drops a socket,
                // which is precisely the failure the endpoint list exists to
                // survive.
                throw RoutingDataSourceError.providerUnavailable(error.localizedDescription)
            default:
                throw RoutingDataSourceError.malformedResponse(error.localizedDescription)
            }
        }
    }
}

/// Raw OSM path data, straight from an Overpass endpoint to the phone.
///
/// No part of Looper's own service is involved in this path and none may be:
/// the app contacts the OSM data provider itself. Overpass is a *data source*,
/// not a router — it returns ways and nodes, and every routing decision made
/// on them happens on the device afterwards.
public struct OverpassRoutingDataSource: RoutingDataSource {
    public struct Configuration: Sendable {
        /// The providers to try, in order.
        ///
        /// A list rather than a single URL because a single one is a single
        /// point of failure, and this was learned the hard way: a burst of
        /// large bounding-box queries during development got the address
        /// blocked by `overpass-api.de`, which does not refuse politely — it
        /// simply stops answering. With one endpoint configured, on-device
        /// routing then stops working with no way for the app to recover.
        ///
        /// Still replaceable wholesale: a commercial Overpass-compatible
        /// endpoint is a one-element list here and no change anywhere else.
        public var endpoints: [URL]
        /// The `[timeout:]` given to Overpass, and the basis of the client's
        /// own request timeout.
        public var serverTimeoutSeconds: Int
        /// Attempts per endpoint before moving on to the next one.
        public var maxAttempts: Int
        /// First backoff step; doubled per attempt, with jitter.
        public var retryDelaySeconds: Double
        /// How long the whole thing may take, across every provider and every
        /// retry, before it gives up.
        ///
        /// Without this, three providers × two attempts × a 75-second timeout
        /// is nearly eight minutes of a button that says "Downloading walking
        /// paths for this area…" and means "everything I know about is
        /// broken". A walker reads that as the app being stuck, which is a
        /// fair reading. A real first download of a town takes well under a
        /// minute, so the budget below is generous to success and merciless to
        /// failure — which is the right way round.
        public var totalDeadlineSeconds: Double

        public init(
            endpoints: [URL] = Configuration.publicOverpassEndpoints,
            serverTimeoutSeconds: Int = 60,
            maxAttempts: Int = 2,
            retryDelaySeconds: Double = 2,
            totalDeadlineSeconds: Double = 90
        ) {
            self.endpoints = endpoints.isEmpty ? Configuration.publicOverpassEndpoints : endpoints
            self.serverTimeoutSeconds = serverTimeoutSeconds
            self.maxAttempts = maxAttempts
            self.retryDelaySeconds = retryDelaySeconds
            self.totalDeadlineSeconds = totalDeadlineSeconds
        }

        /// One endpoint, for a test or a pinned commercial provider.
        public init(
            endpoint: URL,
            serverTimeoutSeconds: Int = 60,
            maxAttempts: Int = 2,
            retryDelaySeconds: Double = 2,
            totalDeadlineSeconds: Double = 90
        ) {
            self.init(
                endpoints: [endpoint], serverTimeoutSeconds: serverTimeoutSeconds,
                maxAttempts: maxAttempts, retryDelaySeconds: retryDelaySeconds,
                totalDeadlineSeconds: totalDeadlineSeconds
            )
        }

        public static let publicOverpass = URL(string: "https://overpass-api.de/api/interpreter")!

        /// The public instances, the main one first. All are volunteer-run and
        /// none is a production backend; the list buys resilience during
        /// development, not permission to lean on them.
        public static let publicOverpassEndpoints: [URL] = [
            publicOverpass,
            URL(string: "https://overpass.kumi.systems/api/interpreter")!,
            URL(string: "https://overpass.private.coffee/api/interpreter")!,
        ]

        public static let standard = Configuration()

        /// The endpoint named first, for reporting.
        public var primaryEndpoint: URL { endpoints[0] }
    }

    private let configuration: Configuration
    private let transport: OverpassTransport
    private let audit: RoutingAudit?

    public init(
        configuration: Configuration = .standard,
        transport: OverpassTransport = URLSessionOverpassTransport(),
        audit: RoutingAudit? = .shared
    ) {
        self.configuration = configuration
        self.transport = transport
        self.audit = audit
    }

    /// The query.
    ///
    /// `way["highway"](bbox)` selects the ways whose geometry intersects the
    /// area. `(._;>;)` then adds every node those ways reference — crucially
    /// *including nodes outside the bounding box*, because a lane that leaves
    /// the area and comes back must not arrive as two disconnected stubs. The
    /// `qt` ordering is Overpass's cheapest, and nothing here depends on
    /// element order.
    public static func query(for bounds: GeographicBounds, timeoutSeconds: Int) -> String {
        let box = String(
            format: "%.6f,%.6f,%.6f,%.6f",
            bounds.south, bounds.west, bounds.north, bounds.east
        )
        return """
        [out:json][timeout:\(timeoutSeconds)];
        way["highway"](\(box));
        (._;>;);
        out body qt;
        """
    }

    public func fetchArea(_ bounds: GeographicBounds) async throws -> OSMData {
        let query = OverpassRoutingDataSource.query(for: bounds, timeoutSeconds: configuration.serverTimeoutSeconds)
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "data", value: query)]
        let body = Data((form.percentEncodedQuery ?? "").utf8)
        let began = Date()
        var attempts = 0
        var lastError = RoutingDataSourceError.malformedResponse("The map data request was never sent.")
        let box = RoutingLog.box(bounds)

        RoutingLog.data.info("osm fetch begin source=Overpass bbox=\(box, privacy: .public) providers=\(configuration.endpoints.count) requestBytes=\(body.count)")

        for endpoint in configuration.endpoints {
            let host = endpoint.host ?? "?"
            for attempt in 1...max(1, configuration.maxAttempts) {
                guard Date().timeIntervalSince(began) < configuration.totalDeadlineSeconds else {
                    RoutingLog.data.notice("osm fetch deadline reached after \(attempts) attempt(s)")
                    break
                }
                attempts += 1
                do {
                    let (data, status) = try await transport.post(
                        url: endpoint,
                        body: body,
                        timeout: Double(configuration.serverTimeoutSeconds) + 10
                    )
                    if status == 429 || (500..<600).contains(status) {
                        lastError = status == 429 ? .rateLimited : .httpStatus(status)
                        RoutingLog.data.notice("osm fetch host=\(host, privacy: .public) status=\(status) attempt=\(attempt)")
                        if attempt < configuration.maxAttempts { try await backOff(afterAttempt: attempt) }
                        continue
                    }
                    guard (200..<300).contains(status) else { throw RoutingDataSourceError.httpStatus(status) }
                    let parsed = try OverpassJSON.parse(data)
                    let ms = Int(Date().timeIntervalSince(began) * 1000)
                    RoutingLog.data.info("osm fetch ok source=Overpass host=\(host, privacy: .public) bbox=\(box, privacy: .public) requestBytes=\(body.count) responseBytes=\(data.count) ways=\(parsed.ways.count) nodes=\(parsed.nodes.count) attempts=\(attempts) ms=\(ms)")
                    await audit?.record(RoutingAudit.OverpassRequest(
                        at: began,
                        endpoint: endpoint.absoluteString,
                        bounds: bounds,
                        requestBytes: body.count,
                        responseBytes: data.count,
                        ways: parsed.ways.count,
                        nodes: parsed.nodes.count,
                        attempts: attempts,
                        durationMs: Date().timeIntervalSince(began) * 1000,
                        failure: nil
                    ))
                    return parsed
                } catch let error as RoutingDataSourceError {
                    lastError = error
                    guard error.isWorthAnotherEndpoint else {
                        // Offline needs a network and cancelled was asked to
                        // stop. Neither is another provider's problem.
                        RoutingLog.data.error("osm fetch abandoned host=\(host, privacy: .public) reason=\(error.terseReason, privacy: .public)")
                        await recordFailure(bounds: bounds, began: began, attempts: attempts, requestBytes: body.count, endpoint: endpoint, error: error)
                        throw error
                    }
                    RoutingLog.data.notice("osm fetch failed host=\(host, privacy: .public) attempt=\(attempt) reason=\(error.terseReason, privacy: .public)")
                    if attempt < configuration.maxAttempts { try await backOff(afterAttempt: attempt) }
                } catch {
                    lastError = .malformedResponse(error.localizedDescription)
                    RoutingLog.data.notice("osm fetch failed host=\(host, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
                    if attempt < configuration.maxAttempts { try await backOff(afterAttempt: attempt) }
                }
            }
            RoutingLog.data.notice("osm provider exhausted host=\(host, privacy: .public)")
            if Date().timeIntervalSince(began) >= configuration.totalDeadlineSeconds { break }
        }

        // Every configured provider was tried and none answered. Say that,
        // rather than blaming the walker's connection.
        let plural = configuration.endpoints.count == 1 ? "" : "s"
        let summary = RoutingDataSourceError.providerUnavailable(
            "Tried \(configuration.endpoints.count) provider\(plural); last error was \(lastError.terseReason)"
        )
        RoutingLog.data.error("osm fetch gave up attempts=\(attempts) reason=\(summary.terseReason, privacy: .public)")
        await recordFailure(bounds: bounds, began: began, attempts: attempts, requestBytes: body.count, endpoint: configuration.primaryEndpoint, error: summary)
        throw summary
    }

    private func recordFailure(bounds: GeographicBounds, began: Date, attempts: Int, requestBytes: Int, endpoint: URL, error: Error) async {
        await audit?.record(RoutingAudit.OverpassRequest(
            at: began,
            endpoint: endpoint.absoluteString,
            bounds: bounds,
            requestBytes: requestBytes,
            responseBytes: 0,
            ways: 0,
            nodes: 0,
            attempts: attempts,
            durationMs: Date().timeIntervalSince(began) * 1000,
            failure: (error as? LocalizedError)?.errorDescription ?? "\(error)"
        ))
    }

    private func backOff(afterAttempt attempt: Int) async throws {
        let base = configuration.retryDelaySeconds * pow(2, Double(attempt - 1))
        let jittered = base * Double.random(in: 0.7...1.3)
        try await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
    }
}

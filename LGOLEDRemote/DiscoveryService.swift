import Foundation
import Darwin
import Network

protocol DiscoveryServicing: AnyObject {
    var onDevicesUpdated: (([LGTVDevice]) -> Void)? { get set }
    var onStatusChanged: ((String) -> Void)? { get set }
    func startDiscovery()
    func stopDiscovery()
}

final class DiscoveryService: NSObject, DiscoveryServicing {
    var onDevicesUpdated: (([LGTVDevice]) -> Void)?
    var onStatusChanged: ((String) -> Void)?

    private let logger: Logger
    private let browserTypes = ["_lgsmarttv._tcp.", "_lgtv2._tcp."]
    private var browsers: [NetServiceBrowser] = []
    private var resolvingServices: Set<NetService> = []
    private var devices: [String: LGTVDevice] = [:]
    private var ssdpTask: Task<Void, Never>?

    init(logger: Logger) {
        self.logger = logger
    }

    func startDiscovery() {
        stopDiscovery()
        devices.removeAll()
        onStatusChanged?("Browsing Bonjour and SSDP services…")

        for type in browserTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }

        startSSDPDiscovery()
    }

    func stopDiscovery() {
        for browser in browsers { browser.stop() }
        browsers.removeAll()

        for service in resolvingServices { service.stop() }
        resolvingServices.removeAll()

        ssdpTask?.cancel()
        ssdpTask = nil
    }

    // MARK: – Bonjour helpers

    private func upsertDevice(from service: NetService) {
        let host = service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                   ?? resolveIPAddress(from: service.addresses)
        guard let host, !host.isEmpty else { return }

        let id = "\(service.name)-\(host)"
        let port = service.port > 0 ? service.port : 3000
        let device = LGTVDevice(id: id, name: service.name, host: host, port: port, macAddress: nil)
        devices[id] = device
        emitDevices()
        logger.info("[Bonjour] Resolved: \(service.name) → \(host):\(port)")
    }

    private func upsertDevice(_ device: LGTVDevice) {
        devices[device.id] = device
        emitDevices()
    }

    private func emitDevices() {
        let sorted = Array(devices.values).sorted { $0.name < $1.name }
        onDevicesUpdated?(sorted)
        onStatusChanged?("Found \(devices.count) TV(s)")
    }

    private func removeDevice(for service: NetService) {
        let keyPrefix = service.name + "-"
        let keys = devices.keys.filter { $0.hasPrefix(keyPrefix) }
        keys.forEach { devices.removeValue(forKey: $0) }
        onDevicesUpdated?(Array(devices.values).sorted { $0.name < $1.name })
    }

    private func resolveIPAddress(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for data in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = data.withUnsafeBytes { rawBuffer -> Int32 in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return -1 }
                return getnameinfo(ptr, socklen_t(data.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            }
            if result == 0 { return String(cString: hostname) }
        }
        return nil
    }

    // MARK: – SSDP (POSIX UDP socket)
    //
    // We use a plain POSIX UDP socket instead of NWConnection so we can:
    //   1. Bind to an ephemeral local port.
    //   2. Send the M-SEARCH multicast to 239.255.255.250:1900.
    //   3. Receive unicast HTTP responses from any TV IP (NWConnection "connected" to
    //      the multicast group may filter out unicast packets from different senders).

    private func startSSDPDiscovery() {
        ssdpTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runSSDPSocket()
        }
    }

    /// Returns the IPv4 address of the active Wi-Fi interface (en0), or nil if not on Wi-Fi.
    private func wifiInterfaceAddress() -> in_addr? {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var ifa = ifap
        while let addr = ifa {
            if String(cString: addr.pointee.ifa_name) == "en0",
               let sa = addr.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET) {
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
            }
            ifa = addr.pointee.ifa_next
        }
        return nil
    }

    private func runSSDPSocket() async {
        // iOS returns EHOSTUNREACH (errno 65) for multicast sendto when no interface
        // is specified. We must bind to the Wi-Fi (en0) IP and set IP_MULTICAST_IF
        // so the kernel routes the packet through Wi-Fi instead of cellular/loopback.
        guard let wifiAddr = wifiInterfaceAddress() else {
            logger.warning("[SSDP] en0 not found — device not on Wi-Fi, skipping SSDP")
            onStatusChanged?("Connect iPhone to Wi-Fi and tap Discover again.")
            return
        }
        var wifiAddrVar = wifiAddr
        var ifBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &wifiAddrVar, &ifBuf, socklen_t(ifBuf.count))
        logger.info("[SSDP] Outgoing interface: \(String(cString: ifBuf))")

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            logger.warning("[SSDP] socket() failed errno=\(errno)")
            return
        }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to the Wi-Fi interface IP so traffic is routed through en0.
        var localAddr = sockaddr_in()
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = 0
        localAddr.sin_addr = wifiAddr
        withUnsafePointer(to: &localAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Explicitly set the outgoing multicast interface to en0.
        // Without this, iOS has no multicast route and returns EHOSTUNREACH.
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF,
                   &wifiAddrVar, socklen_t(MemoryLayout<in_addr>.size))

        // Multicast TTL – 4 hops is more than enough for a local LAN.
        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        // Build and send M-SEARCH.
        let query = "M-SEARCH * HTTP/1.1\r\n" +
                    "HOST: 239.255.255.250:1900\r\n" +
                    "MAN: \"ssdp:discover\"\r\n" +
                    "MX: 3\r\n" +
                    "ST: ssdp:all\r\n\r\n"

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1900).bigEndian
        inet_aton("239.255.255.250", &dest.sin_addr)

        let queryBytes = Array(query.utf8)
        var bytesSent: Int = 0
        queryBytes.withUnsafeBytes { ptr in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bytesSent = sendto(sock, ptr.baseAddress, queryBytes.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if bytesSent > 0 {
            logger.info("[SSDP] M-SEARCH sent (\(bytesSent) bytes) to 239.255.255.250:1900")
        } else {
            logger.error("[SSDP] M-SEARCH sendto failed — errno=\(errno). Local network permission may be denied.")
        }

        // SO_RCVTIMEO: 1-second receive timeout so we can poll Task.isCancelled.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let deadline = Date().addingTimeInterval(6)
        var buf = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            if Task.isCancelled { break }
            let n = recv(sock, &buf, buf.count, 0)
            if n > 0 {
                handleSSDPResponse(Data(buf[..<n]))
            }
        }

        let count = devices.count
        logger.info("[SSDP] Discovery finished. Total devices found: \(count)")
        if count == 0 {
            onStatusChanged?("No TVs found via SSDP. Try manual IP entry.")
        }
    }

    // MARK: – SSDP response parsing

    private func handleSSDPResponse(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let headers = parseHTTPHeaders(text)

        // Log every SSDP response so we can diagnose what the TV is actually sending.
        let server   = headers["server"] ?? "(no server)"
        let st       = headers["st"]     ?? "(no st)"
        let location = headers["location"] ?? "(no location)"
        logger.debug("[SSDP] Response — server: \(server) | st: \(st) | location: \(location)")

        guard let locationURL = URL(string: location) else { return }

        let fingerprint = (headers["server"] ?? "") + " " + (headers["st"] ?? "") +
                          " " + (headers["usn"] ?? "") + " " + (headers["location"] ?? "")
        let lowerFP   = fingerprint.lowercased()
        let lowerBody = text.lowercased()

        // Accept any response that looks LG/webOS-related.
        // Some firmware versions use "LG" (not "LGE") in the server string.
        let isLG = lowerFP.contains("webos") || lowerFP.contains("lge") ||
                   lowerFP.contains(" lg")   || lowerFP.contains("lgsmarttv") ||
                   lowerBody.contains("webos") || lowerBody.contains("lge") ||
                   lowerBody.contains("lgsmarttv")
        guard isLG else {
            logger.debug("[SSDP] Filtered (not LG/webOS): server=\(server)")
            return
        }

        guard let host = locationURL.host, !host.isEmpty else { return }
        let port = locationURL.port ?? 3000
        let usn  = headers["usn"] ?? host
        let id   = "ssdp-\(usn)-\(host)"

        let device = LGTVDevice(
            id: id,
            name: headers["server"]?.contains("webOS") == true ? "LG webOS TV" : "LG TV",
            host: host,
            port: port,
            macAddress: nil
        )
        upsertDevice(device)
        logger.info("[SSDP] Found device: \(device.name) at \(host):\(port)")
        fetchFriendlyName(from: locationURL, id: id)
    }

    private func parseHTTPHeaders(_ response: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in response.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key   = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private func fetchFriendlyName(from locationURL: URL, id: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: locationURL),
                  let xml = String(data: data, encoding: .utf8),
                  let friendlyName = extractXMLTag("friendlyName", from: xml),
                  !friendlyName.isEmpty else { return }

            guard var existing = self.devices[id] else { return }
            existing = LGTVDevice(
                id: existing.id,
                name: friendlyName,
                host: existing.host,
                port: existing.port,
                macAddress: existing.macAddress
            )
            self.upsertDevice(existing)
            self.logger.info("[SSDP] Friendly name updated: \(friendlyName)")
        }
    }

    private func extractXMLTag(_ tag: String, from xml: String) -> String? {
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: – NetServiceBrowserDelegate

extension DiscoveryService: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        logger.info("[Bonjour] Started searching")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onStatusChanged?("Bonjour discovery failed")
        logger.error("[Bonjour] Search failed: \(errorDict)")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.insert(service)
        service.resolve(withTimeout: 5.0)
        if !moreComing {
            onStatusChanged?("Resolving discovered TVs…")
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        removeDevice(for: service)
        if !moreComing {
            onStatusChanged?("Updated TV list")
        }
    }
}

// MARK: – NetServiceDelegate

extension DiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        upsertDevice(from: sender)
        resolvingServices.remove(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        logger.warning("[Bonjour] Resolve failed for \(sender.name): \(errorDict)")
        resolvingServices.remove(sender)
    }
}

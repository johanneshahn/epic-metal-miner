import Darwin
import Foundation

/// Minimal native TCP transport for Epic's newline-delimited JSON-RPC Stratum.
/// It deliberately has no mining policy: that belongs in the job controller.
final class EpicStratumSocket {
    private var fd: Int32 = -1
    private var receiveBuffer = [UInt8]()

    deinit { close() }

    func connect(endpoint: String, timeoutSeconds: Int = 10) throws {
        close()
        let parts = endpoint.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0 else {
            throw EpicMiningError.invalidEndpoint(endpoint)
        }

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var first: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(String(parts[0]), String(port), &hints, &first)
        guard status == 0, let first else {
            throw EpicMiningError.invalidEndpoint("\(endpoint): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            let candidate = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if candidate >= 0 {
                var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
                _ = withUnsafePointer(to: &timeout) {
                    setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
                }
                _ = withUnsafePointer(to: &timeout) {
                    setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
                }
                if Darwin.connect(candidate, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    fd = candidate
                    return
                }
                Darwin.close(candidate)
            }
            current = info.pointee.ai_next
        }
        throw EpicMiningError.invalidEndpoint("could not connect to \(endpoint): \(String(cString: strerror(errno)))")
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    func sendJSON(_ message: [String: Any]) throws {
        guard fd >= 0 else { throw EpicMiningError.malformedMessage("send on disconnected socket") }
        guard JSONSerialization.isValidJSONObject(message) else {
            throw EpicMiningError.malformedMessage("outgoing JSON is invalid")
        }
        var bytes = try JSONSerialization.data(withJSONObject: message, options: []).map { $0 }
        bytes.append(0x0a)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            guard sent > 0 else {
                throw EpicMiningError.malformedMessage("socket write failed: \(String(cString: strerror(errno)))")
            }
            offset += sent
        }
    }

    func readJSONLine() throws -> [String: Any] {
        guard fd >= 0 else { throw EpicMiningError.malformedMessage("read on disconnected socket") }
        while true {
            if let newline = receiveBuffer.firstIndex(of: 0x0a) {
                let line = Array(receiveBuffer[..<newline])
                receiveBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let object = try JSONSerialization.jsonObject(with: Data(line))
                guard let message = object as? [String: Any] else {
                    throw EpicMiningError.malformedMessage("JSON-RPC line is not an object")
                }
                return message
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else {
                let reason = count == 0 ? "peer disconnected" : String(cString: strerror(errno))
                throw EpicMiningError.malformedMessage("socket read failed: \(reason)")
            }
            receiveBuffer.append(contentsOf: chunk[0..<count])
            // JSON-RPC messages are tiny. This rejects a peer that never sends
            // a newline instead of growing the process indefinitely.
            guard receiveBuffer.count <= 1_048_576 else {
                throw EpicMiningError.malformedMessage("received line exceeds 1 MiB")
            }
        }
    }

    /// Poll without consuming a message. The mining loop calls this between
    /// bounded GPU batches so an asynchronous `job` notification can cancel
    /// obsolete work before any candidate is submitted.
    func hasReadableLine() -> Bool {
        if receiveBuffer.contains(0x0a) { return true }
        guard fd >= 0 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&descriptor, 1, 0) > 0
    }
}

func epicRPCRequest(id: String, method: String, params: Any? = nil) -> [String: Any] {
    var request: [String: Any] = ["id": id, "jsonrpc": "2.0", "method": method]
    if let params { request["params"] = params }
    return request
}

func decodeEpicTemplate(_ value: Any) throws -> EpicJobTemplate {
    let data = try JSONSerialization.data(withJSONObject: value, options: [])
    do {
        return try JSONDecoder().decode(EpicJobTemplate.self, from: data)
    } catch {
        throw EpicMiningError.malformedTemplate("\(error)")
    }
}

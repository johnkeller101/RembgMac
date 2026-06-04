import Foundation

/// HTTP server on port 7100 that proxies /api/ requests to rembg on port 7001.
/// Returns 503 when the model is downloading, and exposes /status for health checks.
/// Uses NWListener + URLSession for proper HTTP handling instead of raw sockets.
final class ProxyServer: @unchecked Sendable {
    private let rembgPort = 7001
    private let listenPort: UInt16 = 7100
    private var serverSocket: Int32 = -1
    private var isListening = false
    private let queue = DispatchQueue(label: "com.rembgmac.proxy", attributes: .concurrent)
    private let maxConcurrentRembg = 2

    var getStatus: (() -> ServerStatus)?
    var getRequestCount: (() -> Int)?
    var onRequestCompleted: (() -> Void)?
    var onLog: ((String) -> Void)?
    var rembgPid: (() -> Int32?)?

    func start() {
        stop()
        onLog?("[proxy] Starting proxy on :\(listenPort)...")

        queue.async { [weak self] in
            self?.startInternal()
        }
    }

    private func startInternal() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            onLog?("[proxy] Failed to create socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            onLog?("[proxy] Failed to bind to port \(listenPort): \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        guard listen(serverSocket, 128) == 0 else {
            onLog?("[proxy] Failed to listen: \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        isListening = true
        onLog?("[proxy] Listening on :\(listenPort), forwarding to rembg on :\(rembgPort)")

        acceptLoop()
    }

    func stop() {
        isListening = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    private func acceptLoop() {
        while isListening {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocket, sockPtr, &addrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isListening { continue }
                break
            }

            queue.async { [weak self] in
                self?.handleConnection(clientSocket)
            }
        }
    }

    private func handleConnection(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read the full HTTP request from the client
        var requestData = Data()
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read headers first
        while true {
            let bytesRead = recv(clientSocket, buffer, bufferSize, 0)
            if bytesRead <= 0 { break }
            requestData.append(buffer, count: bytesRead)

            if let headerEnd = requestData.range(of: Data("\r\n\r\n".utf8)) {
                let headerStr = String(data: requestData[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let contentLength = parseContentLength(headerStr)
                let bodyStart = headerEnd.upperBound
                let bodyReceived = requestData.count - bodyStart
                let bodyRemaining = contentLength - bodyReceived

                if bodyRemaining > 0 {
                    var remaining = bodyRemaining
                    while remaining > 0 {
                        let toRead = min(remaining, bufferSize)
                        let bytesRead = recv(clientSocket, buffer, toRead, 0)
                        if bytesRead <= 0 { break }
                        requestData.append(buffer, count: bytesRead)
                        remaining -= bytesRead
                    }
                }
                break
            }

            if requestData.count > 50 * 1024 * 1024 { break }
        }

        guard !requestData.isEmpty else { return }

        // Parse the request
        guard let headerEnd = requestData.range(of: Data("\r\n\r\n".utf8)),
              let headerStr = String(data: requestData[..<headerEnd.lowerBound], encoding: .utf8),
              let firstLine = headerStr.components(separatedBy: "\r\n").first else {
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])

        // Handle /status and any non-API path locally
        if !path.hasPrefix("/api/") {
            let status = getStatus?() ?? .stopped
            let count = getRequestCount?() ?? 0
            let statusStr: String
            let ready: Bool
            switch status {
            case .running:
                statusStr = "ready"
                ready = true
            case .downloadingModel:
                statusStr = "downloading_model"
                ready = false
            case .starting:
                statusStr = "starting"
                ready = false
            case .unhealthy:
                statusStr = "unhealthy"
                ready = false
            default:
                statusStr = "stopped"
                ready = false
            }
            let json = "{\"status\":\"\(statusStr)\",\"ready\":\(ready),\"requests_processed\":\(count)}"
            sendResponse(clientSocket, status: 200, statusText: "OK", contentType: "application/json", body: Data(json.utf8))
            return
        }

        // For /api/remove — check if model is downloading
        if path.hasPrefix("/api/remove") {
            let status = getStatus?() ?? .stopped
            if case .downloadingModel = status {
                let json = "{\"status\":\"downloading_model\",\"message\":\"Model is being downloaded, please retry shortly\"}"
                sendResponse(clientSocket, status: 503, statusText: "Service Unavailable", contentType: "application/json", body: Data(json.utf8), extraHeaders: "Retry-After: 30\r\n")
                return
            }
        }

        // Forward to rembg using URLSession for proper HTTP handling
        let bodyData = requestData[headerEnd.upperBound...]

        // Parse headers from the original request
        let headerLines = headerStr.components(separatedBy: "\r\n").dropFirst() // skip request line
        var contentType = "application/octet-stream"
        for line in headerLines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-type:") {
                contentType = String(line.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Build URLRequest to rembg
        let rembgURL = URL(string: "http://127.0.0.1:\(rembgPort)\(path)")!
        var urlRequest = URLRequest(url: rembgURL)
        urlRequest.httpMethod = method
        urlRequest.httpBody = Data(bodyData)
        urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300 // 5 min for large images

        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()
        var responseCode = 502
        var responseContentType = "application/octet-stream"

        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error {
                let json = "{\"error\":\"rembg proxy error: \(error.localizedDescription)\"}"
                responseData = Data(json.utf8)
                responseCode = 502
                responseContentType = "application/json"
            } else if let http = response as? HTTPURLResponse, let data {
                responseData = data
                responseCode = http.statusCode
                responseContentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            }
            semaphore.signal()
        }
        task.resume()
        // Wait up to 5 minutes, then cancel if still running
        if semaphore.wait(timeout: .now() + 300) == .timedOut {
            task.cancel()
            let json = "{\"error\":\"rembg timed out after 5 minutes\"}"
            responseData = Data(json.utf8)
            responseCode = 504
            responseContentType = "application/json"
        }

        // Send response back to client
        sendResponse(clientSocket, status: responseCode, statusText: httpStatusText(responseCode), contentType: responseContentType, body: responseData, extraHeaders: "Connection: close\r\n")

        // Count completed requests
        if responseCode == 200 && path.hasPrefix("/api/remove") {
            onRequestCompleted?()
        }
    }

    // MARK: - Helpers

    private func sendResponse(_ socket: Int32, status: Int, statusText: String, contentType: String, body: Data, extraHeaders: String = "") {
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n\(extraHeaders)\r\n"
        let headerData = Data(header.utf8)

        headerData.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = send(socket, base, headerData.count, 0)
        }

        body.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            while sent < body.count {
                let n = send(socket, base + sent, body.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func parseContentLength(_ headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

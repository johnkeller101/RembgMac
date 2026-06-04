import Foundation

final class HealthChecker: @unchecked Sendable {
    private var timer: Timer?
    private var consecutiveFailures = 0
    private let failureThreshold = 3

    func startChecking(interval: TimeInterval = 10, onResult: @escaping (Bool) -> Void) {
        stop()
        consecutiveFailures = 0

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                let healthy = await self.check()
                if healthy {
                    self.consecutiveFailures = 0
                } else {
                    self.consecutiveFailures += 1
                }
                let isHealthy = healthy || self.consecutiveFailures < self.failureThreshold
                await MainActor.run { onResult(isHealthy) }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        consecutiveFailures = 0
    }

    private func check() async -> Bool {
        guard let url = URL(string: "http://localhost:7101/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode < 500
            }
            return false
        } catch {
            return false
        }
    }
}

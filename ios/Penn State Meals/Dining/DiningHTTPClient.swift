import Foundation

struct DiningHTTPResponse: Sendable {
    let data: Data
}

final class DiningHTTPClient: Sendable {
    static let shared = DiningHTTPClient()

    let session: URLSession
    let maximumResponseBytes: Int

    init(
        configuration: URLSessionConfiguration = DiningHTTPClient.defaultConfiguration(),
        maximumResponseBytes: Int = 5 * 1_024 * 1_024
    ) {
        self.session = URLSession(configuration: configuration)
        self.maximumResponseBytes = maximumResponseBytes
#if DEBUG
        self.session.sessionDescription = "MeetAndEat.Dining"
#endif
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        // PSU explicitly marks the ColdFusion menu and nutrition responses as non-cacheable and
        // provides no validators. Typed menu/detail repositories own freshness and last-good data,
        // so avoid spending work in URLCache for responses it cannot reuse.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // PSU's nutrition endpoint resolves each `mid` through the ColdFusion session created by
        // the menu request. Keep that session across menu and detail requests (and app launches).
        configuration.httpCookieStorage = .shared
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.waitsForConnectivity = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    @concurrent
    func data(for request: URLRequest) async throws(DiningSourceError) -> DiningHTTPResponse {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()

            guard let response = response as? HTTPURLResponse else {
                throw DiningSourceError.nonHTTPResponse
            }
            guard (200...299).contains(response.statusCode) else {
                throw DiningSourceError.unacceptableStatus(response.statusCode)
            }

            if response.expectedContentLength > Int64(maximumResponseBytes)
                || data.count > maximumResponseBytes {
                throw DiningSourceError.responseTooLarge(limit: maximumResponseBytes)
            }
            guard !data.isEmpty || response.statusCode == 204 else {
                throw DiningSourceError.emptyBody
            }

            return DiningHTTPResponse(data: data)
        } catch let error as DiningSourceError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                throw DiningSourceError.transport(URLError(.cancelled))
            }
            throw DiningSourceError.transport(error)
        } catch is CancellationError {
            throw DiningSourceError.transport(URLError(.cancelled))
        } catch {
            throw DiningSourceError.transport(URLError(.unknown, userInfo: [
                NSUnderlyingErrorKey: error
            ]))
        }
    }

}

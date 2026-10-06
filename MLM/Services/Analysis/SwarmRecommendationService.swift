import Foundation

/// Custom errors thrown while loading recommendations.
enum SwarmError: LocalizedError {
    case lastFmApiKeyMissing
    case lastFmHttpError(statusCode: Int, message: String)
    case lastFmNetworkError(underlying: Error)
    case lastFmDecodingError(underlying: Error)
    
    case soundCloudClientIdMissing
    case soundCloudResolveError(statusCode: Int)
    case soundCloudRelatedError(statusCode: Int)
    case soundCloudNetworkError(underlying: Error)
    case soundCloudSearchEmpty(query: String)
    
    var errorDescription: String? {
        switch self {
        case .lastFmApiKeyMissing:
            return "Last.fm not configured — add an API key in Settings."
        case .lastFmHttpError(let statusCode, _):
            return "Last.fm could not load recommendations (HTTP \(statusCode))."
        case .lastFmNetworkError:
            return "Last.fm network error."
        case .lastFmDecodingError:
            return "Last.fm returned an invalid response."
            
        case .soundCloudClientIdMissing:
            return "SoundCloud is not configured. Add a client ID in Settings."
        case .soundCloudResolveError(let statusCode):
            return "SoundCloud could not resolve this track (HTTP \(statusCode))."
        case .soundCloudRelatedError(let statusCode):
            return "SoundCloud could not load recommendations (HTTP \(statusCode))."
        case .soundCloudNetworkError:
            return "SoundCloud network error."
        case .soundCloudSearchEmpty(let query):
            return "No SoundCloud results found for \"\(query)\"."
        }
    }
}

/// Structured recommendation returned by the recommendation service.
struct SwarmRecommendation: Codable, Sendable, Hashable {
    var artist: String
    var title: String
    var source: String // "lastfm" or "soundcloud"
    var sourceId: String? // SoundCloud track ID or Spotify ID
    var scDownloadUrl: String? // If soundcloud, the original track permalink URL
}

/// A unified service for fetching collaborative suggestions from Last.fm and SoundCloud.
final class SwarmRecommendationService: Sendable {
    private let session: URLSession

    enum SwarmSource: String, Codable, Sendable, CaseIterable {
        case soundcloud = "soundcloud"
        case lastfm = "lastfm"
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        self.session = URLSession(configuration: config)
    }

    /// Fetch similar tracks using global swarm intelligence.
    ///
    /// - Parameters:
    ///   - track: The seed track.
    ///   - source: The explicitly chosen SwarmSource (defaulting to .soundcloud).
    /// - Returns: A list of similar tracks found globally.
    func fetchRecommendations(for track: Track, source: SwarmSource = .soundcloud, limit: Int = 10) async throws -> [SwarmRecommendation] {
        switch source {
        case .soundcloud:
            let originalPath = track.originalPath
            
            // Resolve dynamic client_id from scdl.cfg config file
            guard let clientId = SoundCloudCredentials.clientId(), !clientId.isEmpty else {
                throw SwarmError.soundCloudClientIdMissing
            }

            // A: If it is already a SoundCloud track, use its URL to resolve the track ID
            if originalPath.lowercased().contains("soundcloud.com/") {
                AppLogger.shared.info("Starting SoundCloud related lookup via URL for \(track.title)", source: "Recommendations")
                do {
                    let trackId = try await resolveSoundCloudTrackId(url: originalPath, clientId: clientId)
                    let recs = try await fetchSoundCloudRelated(trackId: trackId, clientId: clientId, limit: limit)
                    AppLogger.shared.info("Successfully resolved \(recs.count) SoundCloud recommendations.", source: "Recommendations")
                    return recs
                } catch {
                    AppLogger.shared.error("SoundCloud related lookup failed: \(error.localizedDescription)", source: "Recommendations")
                    throw error
                }
            } else {
                // B: If it is a local track, search SoundCloud by artist + title first
                let searchQuery = "\(track.artist) \(track.title)"
                AppLogger.shared.info("Searching SoundCloud for local track: '\(searchQuery)'", source: "Recommendations")
                
                let trackId: Int64
                do {
                    trackId = try await searchSoundCloudTrack(query: searchQuery, clientId: clientId)
                    AppLogger.shared.info("Resolved local track to SoundCloud ID \(trackId)", source: "Recommendations")
                } catch {
                    AppLogger.shared.error("SoundCloud search failed: \(error.localizedDescription)", source: "Recommendations")
                    throw error
                }
                
                do {
                    let recs = try await fetchSoundCloudRelated(trackId: trackId, clientId: clientId, limit: limit)
                    AppLogger.shared.info("Successfully resolved \(recs.count) SoundCloud recommendations for search ID \(trackId).", source: "Recommendations")
                    return recs
                } catch {
                    AppLogger.shared.error("SoundCloud related lookup failed for search ID \(trackId): \(error.localizedDescription)", source: "Recommendations")
                    throw error
                }
            }
            
        case .lastfm:
            AppLogger.shared.info("Starting Last.fm similar lookup for '\(track.title)' by \(track.artist)", source: "Recommendations")
            do {
                let recs = try await fetchLastFmSimilar(artist: track.artist, title: track.title, limit: limit)
                AppLogger.shared.info("Successfully fetched \(recs.count) Last.fm recommendations.", source: "Recommendations")
                return recs
            } catch {
                AppLogger.shared.error("Last.fm similar lookup failed: \(error.localizedDescription)", source: "Recommendations")
                throw error
            }
        }
    }

    // -----------------------------------------------------------------------------
    // MARK: - Last.fm Implementation
    // -----------------------------------------------------------------------------

    private func fetchLastFmSimilar(artist: String, title: String, limit: Int = 10) async throws -> [SwarmRecommendation] {
        guard let apiKey = CredentialsLoader.credential(key: "LASTFM_API_KEY"), !apiKey.isEmpty else {
            AppLogger.shared.warn("LASTFM_API_KEY not configured in .env", source: "Recommendations")
            throw SwarmError.lastFmApiKeyMissing
        }

        var urlComponents = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        urlComponents.queryItems = [
            URLQueryItem(name: "method", value: "track.getSimilar"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = urlComponents.url else {
            throw SwarmError.lastFmNetworkError(underlying: NSError(domain: "Swarm", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid URL components"]))
        }

        var request = URLRequest(url: url)
        request.setValue("MusicLibraryManager/1.0 (contact@musiclibrary.app)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SwarmError.lastFmNetworkError(underlying: error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SwarmError.lastFmNetworkError(underlying: NSError(domain: "Swarm", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]))
        }
        
        guard httpResponse.statusCode == 200 else {
            var errorMsg = "HTTP error code \(httpResponse.statusCode)"
            if let errorObj = try? JSONDecoder().decode(LastFmErrorResponse.self, from: data) {
                errorMsg = errorObj.message ?? errorMsg
            }
            throw SwarmError.lastFmHttpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        let decoded: LastFmResponse
        do {
            decoded = try JSONDecoder().decode(LastFmResponse.self, from: data)
        } catch {
            throw SwarmError.lastFmDecodingError(underlying: error)
        }
        
        guard let tracks = decoded.similartracks?.track else {
            return []
        }

        return tracks.map { item in
            SwarmRecommendation(
                artist: item.artist.name,
                title: item.name,
                source: "lastfm",
                sourceId: nil,
                scDownloadUrl: nil
            )
        }
    }

    // -----------------------------------------------------------------------------
    // MARK: - SoundCloud Implementation
    // -----------------------------------------------------------------------------

    private func resolveSoundCloudTrackId(url soundCloudUrl: String, clientId: String) async throws -> Int64 {
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        ]

        var resolveComponents = URLComponents(string: "https://api-v2.soundcloud.com/resolve")!
        resolveComponents.queryItems = [
            URLQueryItem(name: "url", value: soundCloudUrl),
            URLQueryItem(name: "client_id", value: clientId)
        ]

        guard let resolveURL = resolveComponents.url else {
            throw SwarmError.soundCloudNetworkError(underlying: NSError(domain: "Swarm", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid SoundCloud Resolve URL"]))
        }
        var resolveRequest = URLRequest(url: resolveURL)
        for (key, val) in headers {
            resolveRequest.setValue(val, forHTTPHeaderField: key)
        }

        let resolveData: Data
        let resolveResponse: URLResponse
        do {
            (resolveData, resolveResponse) = try await session.data(for: resolveRequest)
        } catch {
            throw SwarmError.soundCloudNetworkError(underlying: error)
        }
        
        guard let resolveHttp = resolveResponse as? HTTPURLResponse else {
            throw SwarmError.soundCloudNetworkError(underlying: NSError(domain: "Swarm", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid SoundCloud Resolve HTTP response"]))
        }
        
        guard resolveHttp.statusCode == 200 else {
            throw SwarmError.soundCloudResolveError(statusCode: resolveHttp.statusCode)
        }

        let resolvedTrack = try JSONDecoder().decode(SoundCloudResolveResponse.self, from: resolveData)
        return resolvedTrack.id
    }

    private func searchSoundCloudTrack(query: String, clientId: String) async throws -> Int64 {
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        ]

        var searchComponents = URLComponents(string: "https://api-v2.soundcloud.com/search/tracks")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "limit", value: "1")
        ]

        guard let searchURL = searchComponents.url else {
            throw SwarmError.soundCloudNetworkError(underlying: NSError(domain: "Swarm", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid SoundCloud Search URL"]))
        }
        
        var searchRequest = URLRequest(url: searchURL)
        for (key, val) in headers {
            searchRequest.setValue(val, forHTTPHeaderField: key)
        }

        let searchData: Data
        let searchResponse: URLResponse
        do {
            (searchData, searchResponse) = try await session.data(for: searchRequest)
        } catch {
            throw SwarmError.soundCloudNetworkError(underlying: error)
        }
        
        guard let searchHttp = searchResponse as? HTTPURLResponse else {
            throw SwarmError.soundCloudNetworkError(underlying: NSError(domain: "Swarm", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid SoundCloud Search HTTP response"]))
        }
        
        guard searchHttp.statusCode == 200 else {
            throw SwarmError.soundCloudResolveError(statusCode: searchHttp.statusCode)
        }

        let decoded = try JSONDecoder().decode(SoundCloudSearchResponse.self, from: searchData)
        guard let firstTrack = decoded.collection?.first else {
            throw SwarmError.soundCloudSearchEmpty(query: query)
        }

        return firstTrack.id
    }

    private func fetchSoundCloudRelated(trackId: Int64, clientId: String, limit: Int = 10) async throws -> [SwarmRecommendation] {
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        ]

        var relatedComponents = URLComponents(string: "https://api-v2.soundcloud.com/tracks/\(trackId)/related")!
        relatedComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let relatedURL = relatedComponents.url else {
            throw SwarmError.soundCloudNetworkError(underlying: NSError(domain: "Swarm", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid SoundCloud Related URL"]))
        }
        var relatedRequest = URLRequest(url: relatedURL)
        for (key, val) in headers {
            relatedRequest.setValue(val, forHTTPHeaderField: key)
        }

        let relatedData: Data
        let relatedResponse: URLResponse
        do {
            (relatedData, relatedResponse) = try await session.data(for: relatedRequest)
        } catch {
            throw SwarmError.soundCloudNetworkError(underlying: error)
        }
        
        guard let relatedHttp = relatedResponse as? HTTPURLResponse else {
            throw SwarmError.soundCloudNetworkError(underlying: NSError(domain: "Swarm", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid SoundCloud Related HTTP response"]))
        }
        
        guard relatedHttp.statusCode == 200 else {
            throw SwarmError.soundCloudRelatedError(statusCode: relatedHttp.statusCode)
        }

        let decodedRelated = try JSONDecoder().decode(SoundCloudRelatedResponse.self, from: relatedData)
        guard let collection = decodedRelated.collection else {
            return []
        }

        return collection.map { item in
            SwarmRecommendation(
                artist: item.user?.username ?? "Unknown",
                title: item.title,
                source: "soundcloud",
                sourceId: String(item.id),
                scDownloadUrl: item.permalink_url
            )
        }
    }
}

// -----------------------------------------------------------------------------
// MARK: - Decodable Helpers
// -----------------------------------------------------------------------------

private struct LastFmErrorResponse: Codable {
    let error: Int?
    let message: String?
}

private struct LastFmResponse: Codable {
    let similartracks: SimilarTracks?
    
    struct SimilarTracks: Codable {
        let track: [TrackItem]?
    }
    
    struct TrackItem: Codable {
        let name: String
        let artist: ArtistItem
    }
    
    struct ArtistItem: Codable {
        let name: String
    }
}

private struct SoundCloudResolveResponse: Codable {
    let id: Int64
    let title: String
    let permalink_url: String?
}

private struct SoundCloudSearchResponse: Codable {
    let collection: [SoundCloudSearchItem]?
    
    struct SoundCloudSearchItem: Codable {
        let id: Int64
    }
}

private struct SoundCloudRelatedResponse: Codable {
    let collection: [SoundCloudTrackItem]?
    
    struct SoundCloudTrackItem: Codable {
        let id: Int64
        let title: String
        let permalink_url: String?
        let user: UserItem?
    }
    
    struct UserItem: Codable {
        let username: String
    }
}

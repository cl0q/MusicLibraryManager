import Foundation
import Testing
@testable import MLM

@Suite("Token blob (single keychain item format)")
struct TokenBlobTests {

    /// Whole-second date — the storage format has no sub-second precision.
    private let wholeSecondDate = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func encodeDecodeRoundTrip() throws {
        let blob = TokenStorage.TokenBlob(
            accessToken: "access-123",
            refreshToken: "refresh-456",
            expiryDate: TokenStorage.iso8601Formatter.string(from: wholeSecondDate)
        )

        let data = try TokenStorage.encodeBlob(blob)
        let decoded = try #require(TokenStorage.decodeBlob(data))

        #expect(decoded == blob)
        #expect(decoded.accessToken == "access-123")
        #expect(decoded.refreshToken == "refresh-456")

        let credentials = TokenStorage.credentials(from: decoded)
        #expect(credentials.accessToken == "access-123")
        #expect(credentials.refreshToken == "refresh-456")
        #expect(abs(credentials.expiryDate?.timeIntervalSince(wholeSecondDate) ?? .infinity) < 1)
    }

    @Test func nullFieldsRoundTripAndJsonShape() throws {
        let blob = TokenStorage.TokenBlob(
            accessToken: "access-only",
            refreshToken: nil,
            expiryDate: nil
        )

        let data = try TokenStorage.encodeBlob(blob)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // Only the documented keys, with the documented wire names.
        // (Synthesized Codable omits nil fields; decoding treats
        // missing and explicit null identically — see explicitNullFieldsDecode.)
        #expect(Set(json.keys).isSubset(of: ["access_token", "refresh_token", "expiry_date"]))
        #expect(json["access_token"] as? String == "access-only")
        #expect(json["refresh_token"] == nil || json["refresh_token"] is NSNull)
        #expect(json["expiry_date"] == nil || json["expiry_date"] is NSNull)

        let decoded = try #require(TokenStorage.decodeBlob(data))
        #expect(decoded.accessToken == "access-only")
        #expect(decoded.refreshToken == nil)
        #expect(decoded.expiryDate == nil)
        #expect(TokenStorage.credentials(from: decoded).expiryDate == nil)
    }

    @Test func explicitNullFieldsDecode() throws {
        // The literal spec format (explicit nulls) must decode too.
        let json = """
        {"access_token":"a","refresh_token":null,"expiry_date":null}
        """.data(using: .utf8)!

        let decoded = try #require(TokenStorage.decodeBlob(json))
        #expect(decoded.accessToken == "a")
        #expect(decoded.refreshToken == nil)
        #expect(decoded.expiryDate == nil)
    }

    @Test func legacyExpiryStringDecodes() throws {
        // The legacy 3-item format stored expiry_date as a plain
        // ISO8601DateFormatter string — migration must parse that value.
        let legacyString = ISO8601DateFormatter().string(from: wholeSecondDate)

        let blob = TokenStorage.TokenBlob(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh",
            expiryDate: legacyString
        )
        let data = try TokenStorage.encodeBlob(blob)
        let decoded = try #require(TokenStorage.decodeBlob(data))

        let credentials = TokenStorage.credentials(from: decoded)
        #expect(abs(credentials.expiryDate?.timeIntervalSince(wholeSecondDate) ?? .infinity) < 1)
    }

    @Test func unparseableDataDecodesToNil() throws {
        #expect(TokenStorage.decodeBlob(Data("not json".utf8)) == nil)
        #expect(TokenStorage.decodeBlob(Data("{}".utf8)) == nil)
        #expect(TokenStorage.decodeBlob(Data("42".utf8)) == nil)
        #expect(TokenStorage.decodeBlob(Data("".utf8)) == nil)
    }

    @Test func unparseableExpiryYieldsNilDate() {
        let blob = TokenStorage.TokenBlob(
            accessToken: "access",
            refreshToken: nil,
            expiryDate: "not-a-date"
        )
        #expect(TokenStorage.credentials(from: blob).expiryDate == nil)
    }
}

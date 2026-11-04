// JSONObjectFixture.swift
// Weir — reads JSON a test wrote or encoded back as a dictionary, failing where it is read when it is not an object.

import Foundation
import Testing

/// A test that checks what is written under a key reads the JSON as a
/// dictionary first, and JSON that is not an object fails that test where
/// it is read rather than as a missing key further on.
enum JSONObjectFixture {
    /// `data` read as a JSON object.
    static func object(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the JSON is not an object",
            sourceLocation: sourceLocation
        )
    }

    /// `value` encoded with `encoder` and read back as a JSON object: the
    /// keys it is written under, as a store that uses `encoder` writes them.
    static func object(
        encoding value: some Encodable,
        with encoder: JSONEncoder = JSONEncoder(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any] {
        try object(encoder.encode(value), sourceLocation: sourceLocation)
    }
}

// ResolvedStringCacheTests.swift
// Weir — the remembered words of a localized resource: kept apart by language and value, and only the latest few values of one key.

import Foundation
import Testing
@testable import Weir

struct ResolvedStringCacheTests {
    /// The remembered words are the resource's in its language, its
    /// interpolated values included: another language or another value is
    /// another entry.
    @Test func aRememberedResource_isKeptApartByLanguageAndValue() {
        let ja = Locale(identifier: "ja")
        let en = Locale(identifier: "en")
        #expect(LocalizedStringResource("Unread").resolved(in: ja) == "未読")
        #expect(LocalizedStringResource("Unread").resolved(in: en) == "Unread")
        #expect(LocalizedStringResource("Unread").resolved(in: ja) == "未読")
        let one = 1
        let two = 2
        #expect(LocalizedStringResource("\(one) unread").resolved(in: en) == "1 unread")
        #expect(LocalizedStringResource("\(two) unread").resolved(in: en) == "2 unread")
        #expect(LocalizedStringResource("\(one) unread").resolved(in: en) == "1 unread")
    }

    /// One key stays within its own entry limit when given thousands of
    /// values, while another key retains its entry.
    @Test func manyValuesOfOneKey_keepTheCacheBounded() {
        let cache = ResolvedStringCache()
        let en = Locale(identifier: "en")
        func unread(_ count: Int) -> LocalizedStringResource {
            var resource = LocalizedStringResource("\(count) unread")
            resource.locale = en
            return resource
        }
        var other = LocalizedStringResource("Unread")
        other.locale = en
        #expect(cache.string(for: other) == "Unread")
        for count in 0..<3000 {
            _ = cache.string(for: unread(count))
        }
        #expect(cache.count(ofKeyOf: unread(0)) == ResolvedStringCache.perKeyLimit)
        #expect(cache.count(ofKeyOf: other) == 1)
        // Recent and older values still resolve correctly at capacity.
        #expect(cache.string(for: unread(2999)) == "2,999 unread")
        #expect(cache.string(for: unread(0)) == "0 unread")
        #expect(cache.count(ofKeyOf: unread(0)) == ResolvedStringCache.perKeyLimit)
    }
}

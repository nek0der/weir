// AppLocaleTests.swift
// Weir — which locale the app's text uses for each Display Language
// choice, and how `SettingsStore` keeps it current.
//
// Every input is explicit: the OS language list and the user's locale are
// handed in, and preferences go to an in-memory store, so the host Mac's
// settings never decide a result and nothing is written to `~/Library`.

import Foundation
import Testing
@testable import Weir

@Suite("App locale")
@MainActor
struct AppLocaleTests {
    private let shipped = ["en", "ja"]

    // MARK: - resolvedLocale

    @Test(arguments: [
        (AppLanguage.japanese, "en_US", "ja", "US"),
        (.english, "ja_JP", "en", "JP")
    ])
    func pinnedLanguages_keepTheUsersRegion(choice: AppLanguage, base: String, language: String, region: String) {
        let locale = choice.resolvedLocale(
            preferredLanguages: [base],
            availableLocalizations: shipped,
            base: Locale(identifier: base)
        )
        #expect(locale.language.languageCode?.identifier == language)
        #expect(locale.region?.identifier == region)
    }

    @Test(arguments: [
        (AppLanguage.english, "ja_Jpan_JP@calendar=japanese;fw=mon;hours=h23;measure=metric;numbers=arab", "en", "JP", "Latn"),
        (.japanese, "en_Latn_US@calendar=japanese;fw=mon;hours=h23;measure=metric;numbers=arab", "ja", "US", "Jpan")
    ])
    func pinnedLanguages_keepTheUsersFormatChoices(
        choice: AppLanguage,
        base: String,
        language: String,
        region: String,
        script: String
    ) {
        let locale = choice.resolvedLocale(
            preferredLanguages: [],
            availableLocalizations: shipped,
            base: Locale(identifier: base)
        )
        #expect(locale.language.languageCode?.identifier == language)
        #expect(locale.region?.identifier == region)
        #expect(locale.language.maximalIdentifier.split(separator: "-").contains(Substring(script)))
        #expect(locale.calendar.identifier == .japanese)
        #expect(locale.firstDayOfWeek == .monday)
        #expect(locale.hourCycle == .zeroToTwentyThree)
        #expect(locale.measurementSystem == .metric)
        #expect(locale.numberingSystem.identifier == "arab")
    }

    /// When the language already matches, the user's own locale comes back
    /// untouched, keeping what an identifier cannot carry.
    @Test func matchingLanguage_returnsTheBaseAsIs() {
        let base = Locale(identifier: "ja_JP@calendar=japanese")
        let locale = AppLanguage.japanese.resolvedLocale(
            preferredLanguages: [],
            availableLocalizations: shipped,
            base: base
        )
        #expect(locale == base)
    }

    /// The first language of the OS list that we ship, matched past its
    /// script subtag, in the user's own region.
    @Test(arguments: [
        (["ja-JP", "en-JP"], ["Base", "en", "ja"], "en_JP", "ja", "JP"),
        (["en-GB", "ja-JP"], ["ja", "en"], "ja_JP", "en", "JP"),
        (["ja-Jpan-JP"], ["en", "ja"], "en_US", "ja", "US"),
        (["zh-Hans-CN", "fr-FR", "ja-JP"], ["en", "ja"], "zh_CN", "ja", "CN")
    ])
    func system_followsTheOSLanguageList_toALanguageWeShip(
        preferred: [String],
        available: [String],
        base: String,
        language: String,
        region: String
    ) {
        let locale = AppLanguage.system.resolvedLocale(
            preferredLanguages: preferred,
            availableLocalizations: available,
            base: Locale(identifier: base)
        )
        #expect(locale.language.languageCode?.identifier == language)
        #expect(locale.region == Locale.Region(region))
    }

    @Test(arguments: [
        (["zh-Hans-CN"], ["ja", "en"], "en"),
        (["fr-FR"], ["Base", "ja", "en"], "en"),
        ([], ["ja", "en"], "en"),
        (["ja-JP"], ["Base"], "en"),
        (["ja-JP"], [], "en"),
        (["fr-FR"], ["ja"], "ja")
    ])
    func system_usesDevelopmentLanguageOrTheFirstShippedFallback(
        preferred: [String],
        available: [String],
        expectedLanguage: String
    ) {
        let locale = AppLanguage.system.resolvedLocale(
            preferredLanguages: preferred,
            availableLocalizations: available,
            base: Locale(identifier: "fr_FR")
        )
        #expect(locale.language.languageCode?.identifier == expectedLanguage)
        #expect(locale.region == Locale.Region("FR"))
    }

    @Test func appleLanguagesValue_matchesThePinnedLocalization() {
        #expect(AppLanguage.system.appleLanguagesValue == nil)
        #expect(AppLanguage.english.appleLanguagesValue == ["en"])
        #expect(AppLanguage.japanese.appleLanguagesValue == ["ja"])
    }

    // MARK: - SettingsStore

    private func sources(
        _ defaults: UserDefaults,
        languages: @escaping () -> [String],
        base: Locale = Locale(identifier: "en_JP")
    ) -> AppLanguageSources {
        AppLanguageSources(defaults: defaults, systemPreferredLanguages: languages, currentLocale: { base })
    }

    @Test func store_followsTheSystemListByDefault() throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            let store = SettingsStore(directory: directory, languageSources: sources(defaults) { ["ja-JP"] })
            #expect(store.appLanguage == .system)
            #expect(store.appLocale.language.languageCode == .japanese)
            #expect(store.appLocale.region == Locale.Region("JP"))
        }
    }

    @Test func changingLanguage_updatesLocaleAndLaunchPreference() throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            var languages = ["ja-JP"]
            let store = SettingsStore(directory: directory, languageSources: sources(defaults) { languages })
            #expect(store.appLanguageAtLaunch == .system)
            #expect(!store.needsRelaunchForLanguage)
            #expect(store.appLocale.language.languageCode == .japanese)

            store.appLanguage = .english
            #expect(store.appLocale.language.languageCode == .english)
            #expect(store.appLocale.region == Locale.Region("JP"))
            #expect(defaults.string(forKey: "appLanguage") == "english")
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
            #expect(store.needsRelaunchForLanguage)

            languages = ["en-US"]
            store.appLanguage = .japanese
            #expect(store.appLocale.language.languageCode == .japanese)
            #expect(store.appLocale.region == Locale.Region("JP"))
            #expect(defaults.string(forKey: "appLanguage") == "japanese")
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ja"])
            #expect(store.needsRelaunchForLanguage)

            store.appLanguage = .system
            #expect(store.appLocale.language.languageCode == .english)
            #expect(store.appLocale.region == Locale.Region("JP"))
            #expect(defaults.string(forKey: "appLanguage") == "system")
            #expect(defaults.object(forKey: "AppleLanguages") == nil)
            #expect(!store.needsRelaunchForLanguage)
        }
    }

    @Test(arguments: [
        ("japanese", ["en-US"], AppLanguage.japanese, "ja"),
        ("english", ["ja-JP"], .english, "en"),
        ("unsupported", ["ja-JP"], .system, "ja")
    ])
    func store_readsTheSavedChoiceOrUsesSystemDefault(
        stored: String,
        preferred: [String],
        expectedChoice: AppLanguage,
        expectedLanguage: String
    ) throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            defaults.set(stored, forKey: "appLanguage")
            let store = SettingsStore(directory: directory, languageSources: sources(defaults) { preferred })
            #expect(store.appLanguage == expectedChoice)
            #expect(store.appLanguageAtLaunch == expectedChoice)
            #expect(!store.needsRelaunchForLanguage)
            #expect(store.appLocale.language.languageCode?.identifier == expectedLanguage)
            #expect(store.appLocale.region == Locale.Region("JP"))
        }
    }

    @Test(arguments: [
        (AppLanguage.system, "en", "ja"),
        (.english, "en", "en"),
        (.japanese, "ja", "ja")
    ])
    func localeNotification_updatesRegion_andFollowsLanguageInSystemMode(
        choice: AppLanguage,
        initialLanguage: String,
        updatedLanguage: String
    ) throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            defaults.set(choice.rawValue, forKey: "appLanguage")
            var languages = ["en-US"]
            var base = Locale(identifier: "en_US")
            let store = SettingsStore(directory: directory, languageSources: AppLanguageSources(
                defaults: defaults,
                systemPreferredLanguages: { languages },
                currentLocale: { base }
            ))
            #expect(store.appLocale.language.languageCode?.identifier == initialLanguage)
            #expect(store.appLocale.region?.identifier == "US")

            languages = ["ja-JP"]
            base = Locale(identifier: "en_CA")
            #expect(store.appLocale.region?.identifier == "US")
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)

            #expect(store.appLocale.language.languageCode?.identifier == updatedLanguage)
            #expect(store.appLocale.region?.identifier == "CA")
            #expect(store.appLanguage == choice)
            #expect(!store.needsRelaunchForLanguage)
        }
    }
}

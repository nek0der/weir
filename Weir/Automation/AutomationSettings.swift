// AutomationSettings.swift
// Weir — reading and changing one setting by its key in `settings.json`.

#if DEBUG && WEIR_AUTOMATION

    import Foundation

    /// A setting named as it is written in `settings.json`, with dots between
    /// the levels (`font.family`, `appearance.colorScheme`), as editors'
    /// settings APIs name one. The change goes through
    /// `WeirSettings`'s own decoding, so a value the app would not read from the
    /// file is refused here too, and a key the app does not know is refused
    /// rather than kept as an unknown field the way the file keeps one.
    ///
    /// Two checks catch an unknown key, because the settings types handle one
    /// in two ways: most keep it in `unknownFields`, which `unknownEntries(of:)`
    /// compares before and after; a type with synthesized decoding, such as a
    /// keyboard override, drops it, which the read-back in `setting` catches.
    enum AutomationSettings {
        struct Failure: Error, Equatable, LocalizedError {
            let message: String

            var errorDescription: String? {
                message
            }
        }

        /// The value at `key`, or `.null` for a known key left unset (an
        /// optional setting such as `font.family` is not written until set).
        static func value(at key: String, in settings: WeirSettings) throws -> WeirJSONValue {
            let path = try components(of: key)
            guard try isKnown(path, in: settings) else {
                throw Failure(message: "\(key) is not a setting this build knows")
            }
            return try lookup(path, in: encode(settings)) ?? .null
        }

        /// `settings` with `value` at `key`, normalized as the settings store
        /// normalizes it, so what is returned is what the store would keep.
        /// The checks the Settings window's own controls make before they
        /// write run here too (`refusal(of:from:isTakenBySystem:)`), so a
        /// value its control would refuse or ask about is refused.
        /// `isTakenBySystem` answers as the quick terminal's recorder asks
        /// (`QuickTerminalHotKeyCenter.isTakenBySystem`).
        static func setting(
            _ value: WeirJSONValue,
            at key: String,
            in settings: WeirSettings,
            isTakenBySystem: (StoredShortcut) -> Bool = { _ in false }
        ) throws -> WeirSettings {
            let path = try components(of: key)
            guard path.first != "schemaVersion" else {
                throw Failure(message: "schemaVersion is the file's, not a setting")
            }
            var changed: WeirSettings
            do {
                changed = try decoded(replacing: path, with: value, in: settings)
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(message: "\(key) does not take that value: \(error.localizedDescription)")
            }
            // A key the app keeps as unknown, new or already in the file,
            // shows as a change among the unknown fields.
            guard unknownEntries(of: changed) == unknownEntries(of: settings) else {
                throw Failure(message: "\(key) is not a setting this build knows")
            }
            // The store normalizes keyboard settings on every change; doing it
            // here first means the read-back below sees what will be kept,
            // and a value the store would move aside is refused, not saved.
            changed.normalizeKeyboard()
            // What the app keeps must hold what was asked. A key dropped in
            // decoding is missing here; a group set in part has its other
            // fields filled with defaults, which is still a match.
            let kept = try lookup(path, in: encode(changed)) ?? .null
            guard contains(kept, value) else {
                throw Failure(message: "\(key) is not a setting this build knows, or the app changed the value to \(kept)")
            }
            if let refusal = refusal(of: changed, from: settings, isTakenBySystem: isTakenBySystem) {
                throw Failure(message: refusal)
            }
            // The External Diff Tool field makes smart quotes plain as it
            // takes its text, so a command a person typed runs. Only a change
            // to that field does it, as only typing there does in the app.
            if ["review", "review.externalDiffCommand"].contains(key) {
                changed.review.externalDiffCommand = CommandLineText.sanitizeSmartPunctuation(changed.review.externalDiffCommand)
            }
            return changed
        }

        /// Why the Settings window would not take `changed` as it stands, or
        /// `nil` when it would. These are the checks its controls make in the
        /// view, which the store does not repeat. Each is asked of `settings`,
        /// the bindings before the change, as the recorders ask: normalizing
        /// `changed` has already given up a default the new binding takes,
        /// so a conflict would no longer show there.
        /// - Keep Turns For and Turns per Conversation ask before a narrower
        ///   limit deletes records (`AdvancedPane`). The channel cannot answer
        ///   that question, so it does not narrow them at all.
        /// - The Keyboard pane's recorder refuses a binding another action
        ///   holds or Weir reserves (`KeyboardSettings.validate`).
        /// - The quick terminal's recorder refuses a hotkey without ⌘ or ⌃,
        ///   one Weir reserves, one macOS uses, or one a menu item holds
        ///   (`QuickTerminalSettings.validateHotKey`).
        static func refusal(
            of changed: WeirSettings,
            from settings: WeirSettings,
            isTakenBySystem: (StoredShortcut) -> Bool
        ) -> String? {
            let retention = (old: settings.advanced.turnRetention, new: changed.advanced.turnRetention)
            if retention.new.days < retention.old.days || retention.new.turns < retention.old.turns {
                return "a narrower turn retention deletes records, which Settings asks about first; set it there"
            }
            for (name, keys) in changed.keyboard.overrides where settings.keyboard.overrides[name] != keys {
                guard let action = WeirShortcutAction(rawValue: name) else { continue }
                let validation = settings.keyboard.validate(keys, for: action, quickTerminalHotKey: settings.quickTerminal.hotKey)
                guard validation == .ok else {
                    return "keyboard.overrides.\(name) is refused as the Keyboard pane refuses it: \(validation)"
                }
            }
            if let hotKey = changed.quickTerminal.hotKey, hotKey != settings.quickTerminal.hotKey {
                let validation = settings.quickTerminal.validateHotKey(
                    hotKey,
                    keyboard: settings.keyboard,
                    isTakenBySystem: isTakenBySystem
                )
                guard validation == .ok else {
                    return "quickTerminal.hotKey is refused as the Quick Terminal pane refuses it: \(validation)"
                }
            }
            return nil
        }

        /// Whether the app knows `path`, judged by what its own decoding does
        /// with a probe there, so the answer depends neither on what the file
        /// holds nor on Swift property names, which can differ from the keys
        /// (`reviewFileApplication`). A known field of another type refuses
        /// the probe; a known string or group keeps it; a known choice such
        /// as a confirmation policy reads it as its default, as it reads any
        /// value it does not recognize. Either way the key is still there. An
        /// unknown key either lands among the unknown fields or is dropped.
        private static func isKnown(_ path: [String], in settings: WeirSettings) throws -> Bool {
            let probe = WeirJSONValue.string("weir-automation-probe")
            let changed: WeirSettings
            do {
                changed = try decoded(replacing: path, with: probe, in: settings)
            } catch is Failure {
                // A path through a value rather than a group.
                return false
            } catch {
                return true
            }
            guard unknownEntries(of: changed) == unknownEntries(of: settings) else { return false }
            return try lookup(path, in: encode(changed)) != nil
        }

        private static func decoded(replacing path: [String], with value: WeirJSONValue, in settings: WeirSettings) throws -> WeirSettings {
            let tree = try replacing(path, with: value, in: encode(settings))
            return try JSONDecoder().decode(WeirSettings.self, from: JSONEncoder().encode(tree))
        }

        private static func components(of key: String) throws -> [String] {
            let path = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !key.isEmpty, !path.contains(where: \.isEmpty) else {
                throw Failure(message: "a setting is named like font.family")
            }
            return path
        }

        private static func encode(_ settings: WeirSettings) throws -> WeirJSONValue {
            try JSONDecoder().decode(WeirJSONValue.self, from: JSONEncoder().encode(settings))
        }

        private static func lookup(_ path: [String], in tree: WeirJSONValue) -> WeirJSONValue? {
            guard let head = path.first else { return tree }
            guard case let .object(fields) = tree, let child = fields[head] else { return nil }
            return lookup(Array(path.dropFirst()), in: child)
        }

        private static func replacing(_ path: [String], with value: WeirJSONValue, in tree: WeirJSONValue) throws -> WeirJSONValue {
            guard let head = path.first else { return value }
            guard case var .object(fields) = tree else {
                throw Failure(message: "\(head) is inside a value, not a group of settings")
            }
            // A level not written yet starts empty; decoding then fills in its
            // defaults, or refuses a level the app does not know.
            fields[head] = try replacing(Array(path.dropFirst()), with: value, in: fields[head] ?? .object([:]))
            return .object(fields)
        }

        /// Whether `stored` holds everything in `asked`: the same scalars, with
        /// an integer and a double of one value taken as the same (`13` is read
        /// back as an integer whatever its Swift type), every asked key of an
        /// object, and arrays element by element.
        static func contains(_ stored: WeirJSONValue, _ asked: WeirJSONValue) -> Bool {
            switch (stored, asked) {
            case let (.object(have), .object(want)):
                want.allSatisfy { key, value in have[key].map { contains($0, value) } ?? false }
            case let (.array(have), .array(want)):
                have.count == want.count && zip(have, want).allSatisfy { contains($0, $1) }
            case let (.int(have), .double(want)):
                Double(have) == want
            case let (.double(have), .int(want)):
                have == Double(want)
            default:
                stored == asked
            }
        }

        /// Every field kept as unknown, at every level, with its value, so a
        /// change that adds one, or changes one already in the file, is told
        /// apart from a change the app took. Values with no label, a
        /// dictionary's entries and an array's elements, are walked too: an
        /// unknown field can sit inside a keyboard override as well as in a
        /// group of settings.
        static func unknownEntries(of value: Any, at path: String = "") -> [String: WeirJSONValue] {
            var entries: [String: WeirJSONValue] = [:]
            for child in Mirror(reflecting: value).children {
                // No index in the path: a dictionary's entries come in no fixed
                // order, and the two maps compared must not differ by it.
                let label = child.label ?? "[]"
                let childPath = path.isEmpty ? label : "\(path).\(label)"
                if label == "unknownFields", let fields = child.value as? [String: WeirJSONValue] {
                    for (key, field) in fields {
                        entries["\(path).\(key)"] = field
                    }
                } else {
                    entries.merge(unknownEntries(of: child.value, at: childPath)) { first, _ in first }
                }
            }
            return entries
        }
    }

#endif

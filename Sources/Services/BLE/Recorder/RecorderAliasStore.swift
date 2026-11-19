import Combine
import Foundation


/// The display name of the recorder card within **this App**.
///
/// Same approach as `RecorderIdentityStore` (`UserDefaults` + JSON + reconstructable cache),
/// only that side stores "who this card belongs to", while this side stores "what the user calls it".
///
/// ⚠️ Why `ObservableObject`: after renaming, the UI must **immediately** update. `DiscoveredRecorder.displayName`
/// reads from here, but it is a plain computed property; SwiftUI doesn't know to redraw — therefore the store itself
/// is attached as `@ObservedObject` / `@StateObject`; when `@Published` changes, the whole tree refreshes.
///
/// ⚠️ Why **no** `@MainActor` annotation (the sibling `RecorderIdentityStore` has one):
/// The entry point that reads it is `DiscoveredRecorder.displayName`, which is a **non-isolated computed property**
/// (the struct itself has no isolation annotation, yet it must be callable from any rendering path).
/// If annotated with `@MainActor`, that property would need to be changed to something like `MainActor.assumeIsolated`,
/// or duplicate the alias lookup across the seven call sites — the latter is more prone to omissions.
/// The actual constraint is enforced here: **all writes originate from UI actions** (always on the main thread),
/// reads are just a single dictionary lookup (non‑blocking, no I/O).
final class RecorderAliasStore: ObservableObject {

    static let shared = RecorderAliasStore()

    /// The card's own name limit, taken from the official copy (see the "Length limit 20" heading at the top of this file).
    static let maxLength = 20

    private static let storageKey = "ticnote.recorder_alias.v1"

    /// Alias table. Key = `key(identityHex:peripheralUUID:)`, value = the name entered by the user.
    @Published private(set) var aliases: [String: String] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Key

    /// Normalized key.
    ///
    /// * With identity (SN) → use identity, and **normalize case** (`s02510ycy36w3n9h` and
    ///   `S02510YCY36W3N9H` represent the same card, cannot be stored as two entries);
    /// * Without identity → fall back to peripheral UUID, also normalized.
    /// * Both empty → empty string; callers must treat it as "no key" (**must not** use the empty string for read/write,
    ///   otherwise all cards "without readable identity" would share the same name).
    static func key(identityHex: String, peripheralUUID: String = "") -> String {
        let identity = identityHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !identity.isEmpty { return "sn:" + identity }
        let uuid = peripheralUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !uuid.isEmpty { return "uuid:" + uuid }
        return ""
    }

    /// Validate user input: trim leading/trailing whitespace; if empty or too long, return `nil` (**do not** truncate —
    /// silent truncation would make the user think their input succeeded).
    static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }

    // MARK: Read

    /// Whether a user‑defined name exists (the UI uses this to decide whether to show "Restore card's original name").
    func hasAlias(identityHex: String, peripheralUUID: String = "") -> Bool {
        alias(identityHex: identityHex, peripheralUUID: peripheralUUID) != nil
    }

    /// Fetch alias. `nil` = user has never set one (UI should fall back to the card's own name).
    func alias(identityHex: String, peripheralUUID: String = "") -> String? {
        let k = Self.key(identityHex: identityHex, peripheralUUID: peripheralUUID)
        guard !k.isEmpty else { return nil }
        guard let value = aliases[k], !value.isEmpty else { return nil }
        return value
    }

    // MARK: Write

    /// Naming / renaming / clearing.
    ///
    /// The semantics of the three inputs **must be separated** (this rule came from self‑inspection, not assumption):
    ///
    /// | Input | Action |
    /// |---|---|
    /// | `nil` | **Clear** alias, UI falls back to the card's own name |
    /// | Only whitespace (`"   "`, `""`) | Same as above — user cleared the field, meaning "no alias" |
    /// | After trimming, **too long** | **Reject**, and **keep the original name** |
    ///
    /// The last row is critical: early versions merged "too long" and "clear" into the same path
    /// (`sanitized` returned `nil` for both → fell into `removeValue`),
    /// resulting in the user typing an extra character and clicking save, **the previously good name disappeared**.
    /// This is not "strict validation", it's silent data loss.
    ///
    /// - Returns: after persisting, **the current name of this card** (`nil` = no name: cleared, or never existed).
    ///   When rejected, returns the **unchanged previous value** — the caller can compare to know the write was not applied.
    @discardableResult
    func setAlias(_ name: String?,
                  identityHex: String,
                  peripheralUUID: String = "") -> String? {
        let k = Self.key(identityHex: identityHex, peripheralUUID: peripheralUUID)
        guard !k.isEmpty else { return nil }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        // ① Too long → reject, **do not touch** the existing stored name.
        if let trimmed, !trimmed.isEmpty, trimmed.count > Self.maxLength {
            return aliases[k]
        }

        // ② Non‑empty → write; ③ nil / all whitespace → clear.
        if let trimmed, !trimmed.isEmpty {
            aliases[k] = trimmed
        } else {
            aliases.removeValue(forKey: k)
        }
        persist()
        return aliases[k]
    }

    /// Forget a card's name (called when unbinding — the card is handed over, keeping a name is meaningless).
    func forget(identityHex: String, peripheralUUID: String = "") {
        let k = Self.key(identityHex: identityHex, peripheralUUID: peripheralUUID)
        guard !k.isEmpty, aliases[k] != nil else { return }
        aliases.removeValue(forKey: k)
        persist()
    }

    // MARK: Persist

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        // If it cannot be decoded, treat it as never saved — this is a **reconstructable preference**, not worth erroring,
        // and must not inadvertently delete user‑stored data elsewhere (same as `RecorderIdentityStore.load`).
        aliases = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - A gateway for `DiscoveredRecorder`

extension RecorderAliasStore {

    /// Retrieve alias from a scan result. **This is the only entry point the UI should use** ——
    /// It consolidates the "identity first, UUID fallback" rule in one place, avoiding ad‑hoc key construction at each call site.
    func alias(for recorder: DiscoveredRecorder) -> String? {
        alias(identityHex: recorder.identityHex, peripheralUUID: recorder.id.uuidString)
    }

    /// Assign or clear a name for a scan result.
    @discardableResult
    func setAlias(_ name: String?, for recorder: DiscoveredRecorder) -> String? {
        setAlias(name, identityHex: recorder.identityHex, peripheralUUID: recorder.id.uuidString)
    }
}

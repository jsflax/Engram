import Lattice
import Foundation

/// Per-project configuration for personal device sync and explicit group exposure.
///
/// Each row maps a project name to a sync policy. The special project name `_default`
/// sets the fallback policy for projects without an explicit override.
///
/// When a project is set to `.sync`, non-private memories can sync across personal
/// devices. Private memories remain device-local regardless of this setting.
///
/// The `exposedTeams` field (use the `exposedGroups` alias) controls which groups
/// receive this project's non-private memories through the daemon's per-group relay
/// filters. Exposure is independent of `policy`; an empty set means no group exposure.
@Model
public final class SyncConfig {
    /// The project name this config applies to.
    /// Use `"_default"` for the fallback policy.
    @Unique()
    public var project: String

    @LatticeEnum
    public enum Policy: String, Codable, Sendable {
        /// Disables personal device sync; explicit group exposure can still share non-private memories.
        case local
        /// Enables personal device sync for non-private memories.
        case sync
    }

    /// Whether this project's non-private memories should sync across personal devices.
    public var policy: Policy = .local

    /// Group IDs this project is exposed to (the Groups feature).
    ///
    /// STORED COLUMN NAME IS `exposedTeams` for wire/schema stability across
    /// the user's own devices (SyncConfig replicates via personal sync; a
    /// rename would skew across app versions). Use the `exposedGroups`
    /// alias in new code.
    ///
    /// Exposure gates WRITES only: the daemon's per-group hub filters relay
    /// non-private memories of exposed projects into that group's spoke.
    /// Reads are membership-scoped (every membership spoke attaches on
    /// recall) regardless of exposure. Un-exposing stops NEW sharing;
    /// already-shared rows remain with the group (retract an individual
    /// memory via `is_private`).
    public var exposedTeams: Set<String> = []

    /// Preferred accessor for `exposedTeams` (the stored name predates the
    /// team→group rename).
    public var exposedGroups: Set<String> {
        get { exposedTeams }
        set { exposedTeams = newValue }
    }

    /// When this config was last updated.
    public var updatedAt: Date

    public init(
        project: String,
        policy: Policy,
        exposedTeams: Set<String> = [],
        updatedAt: Date = Date()
    ) {
        self.project = project
        self.policy = policy
        self.exposedTeams = exposedTeams
        self.updatedAt = updatedAt
    }
}

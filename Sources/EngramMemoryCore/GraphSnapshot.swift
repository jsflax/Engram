import EngramGraphContract

// Source-compatible names for existing exporter/service/view callers. The definitions and wire
// encoding live once in the macOS 14 pure package; these aliases introduce no alternate DTOs.
public typealias EngramGraphScope = EngramGraphContract.EngramGraphScope
public typealias EngramGraphError = EngramGraphContract.EngramGraphError
public typealias EngramGraphLimits = EngramGraphContract.EngramGraphLimits
public typealias EngramGraphPosition = EngramGraphContract.EngramGraphPosition
public typealias EngramGraphNode = EngramGraphContract.EngramGraphNode
public typealias EngramGraphEdge = EngramGraphContract.EngramGraphEdge
public typealias EngramGraphSnapshot = EngramGraphContract.EngramGraphSnapshot

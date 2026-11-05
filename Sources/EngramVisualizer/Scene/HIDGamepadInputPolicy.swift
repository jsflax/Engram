import Foundation

/// Value-only descriptor checked by a controller profile before reading input.
struct HIDGamepadElementDescriptor: Equatable, Sendable {
    let reportID: UInt32
    let type: UInt32
    let page: UInt32
    let usage: UInt32
    let minimum: Int
    let maximum: Int
    let isRelative: Bool
    let hasGamepadAncestor: Bool
    let hasKeyboardOrMouseAncestor: Bool
}

enum HIDGamepadChannel: Hashable, Sendable {
    case leftX, leftY, rightX, rightY, leftTrigger, rightTrigger, hat
    case button(Int)
}

/// The reader handles discovery and lifecycle; profiles own device matching,
/// descriptor interpretation and control semantics. Only the descriptor layout
/// observed on hardware is registered here. Control mappings require separate
/// physical acceptance; additional layouts need their own evidence.
enum HIDGamepadProfile: Sendable {
    case xboxWirelessBLE

    var inputReportIDs: Set<UInt32> {
        switch self { case .xboxWirelessBLE: [1] }
    }

    var channels: Set<HIDGamepadChannel> {
        switch self { case .xboxWirelessBLE: XboxWirelessBLEInputPolicy.channels }
    }

    func matchesDevice(vendor: Int, product: Int, usagePage: Int,
                       usage: Int, transport: String) -> Bool {
        switch self {
        case .xboxWirelessBLE:
            XboxWirelessBLEInputPolicy.matchesDevice(vendor: vendor, product: product,
                usagePage: usagePage, usage: usage, transport: transport)
        }
    }

    func channel(for element: HIDGamepadElementDescriptor) -> HIDGamepadChannel? {
        switch self { case .xboxWirelessBLE: XboxWirelessBLEInputPolicy.channel(for: element) }
    }

    func validatesSchema(_ elements: [HIDGamepadElementDescriptor]) -> Bool {
        switch self { case .xboxWirelessBLE: XboxWirelessBLEInputPolicy.validatesSchema(elements) }
    }

    func accepts(rawValue: Int, for channel: HIDGamepadChannel) -> Bool {
        switch self { case .xboxWirelessBLE: XboxWirelessBLEInputPolicy.accepts(rawValue: rawValue, for: channel) }
    }

    func normalized(_ values: [HIDGamepadChannel: Int]) -> HIDGamepadControlValues? {
        switch self { case .xboxWirelessBLE: XboxWirelessBLEInputPolicy.normalized(values) }
    }

    func isNeutral(_ values: [HIDGamepadChannel: Int]) -> Bool {
        switch self { case .xboxWirelessBLE: XboxWirelessBLEInputPolicy.isNeutral(values) }
    }
}

/// Device identity alone does not establish its report layout. Validate the
/// complete observed BLE input layout before accepting controller values.
enum XboxWirelessBLEInputPolicy {
    static let channels: Set<HIDGamepadChannel> = Set([
        .leftX, .leftY, .rightX, .rightY, .leftTrigger, .rightTrigger, .hat
    ] + (1...15).map { .button($0) })

    static func matchesDevice(vendor: Int, product: Int, usagePage: Int,
                              usage: Int, transport: String) -> Bool {
        vendor == 1118 && product == 2895 && usagePage == 1 && usage == 5
            && transport == "Bluetooth Low Energy"
    }

    static func channel(for element: HIDGamepadElementDescriptor) -> HIDGamepadChannel? {
        guard element.reportID == 1, !element.isRelative,
              element.hasGamepadAncestor, !element.hasKeyboardOrMouseAncestor else { return nil }
        switch (element.type, element.page, element.usage, element.minimum, element.maximum) {
        case (1, 1, 48, 0, 65535): return .leftX
        case (1, 1, 49, 0, 65535): return .leftY
        case (1, 1, 50, 0, 65535): return .rightX
        case (1, 1, 53, 0, 65535): return .rightY
        case (1, 1, 57, 1, 8): return .hat
        case (1, 2, 197, 0, 1023): return .leftTrigger
        case (1, 2, 196, 0, 1023): return .rightTrigger
        case (2, 9, 1...15, 0, 1): return .button(Int(element.usage))
        default: return nil
        }
    }

    static func validatesSchema(_ elements: [HIDGamepadElementDescriptor]) -> Bool {
        guard elements.count == channels.count else { return false }
        let mapped = elements.compactMap { channel(for: $0) }
        return mapped.count == elements.count && Set(mapped) == channels
    }

    static func accepts(rawValue: Int, for channel: HIDGamepadChannel) -> Bool {
        switch channel {
        case .leftX, .leftY, .rightX, .rightY: (0...65535).contains(rawValue)
        case .leftTrigger, .rightTrigger: (0...1023).contains(rawValue)
        // Zero is the descriptor's null/no-direction value.
        case .hat: (0...8).contains(rawValue)
        case .button(let number): (1...15).contains(number) && (0...1).contains(rawValue)
        }
    }

    static func isNeutral(_ values: [HIDGamepadChannel: Int]) -> Bool {
        guard let controls = normalized(values) else { return false }
        return abs(controls.leftX) <= 0.1 && abs(controls.leftY) <= 0.1
            && abs(controls.rightX) <= 0.1 && abs(controls.rightY) <= 0.1
            && controls.leftTrigger <= 0.05 && controls.rightTrigger <= 0.05
            && values[.hat] == 0 && (1...15).allSatisfy { values[.button($0)] == 0 }
    }

    static func normalized(_ values: [HIDGamepadChannel: Int]) -> HIDGamepadControlValues? {
        guard Set(values.keys) == channels,
              values.allSatisfy({ accepts(rawValue: $0.value, for: $0.key) }) else { return nil }
        func stick(_ channel: HIDGamepadChannel) -> Float {
            Float(values[channel]!) / 32767.5 - 1
        }
        func pressed(_ button: Int) -> Bool { values[.button(button)] == 1 }
        // Xbox's 15-button BLE layout leaves gaps at 3 and 6. These assignments
        // follow that layout; Nano navigation still requires physical validation.
        let buttonUsages = [1, 2, 4, 5, 7, 8]
        var buttons: UInt8 = 0
        for (bit, usage) in buttonUsages.enumerated() where pressed(usage) {
            buttons |= 1 << bit
        }
        return HIDGamepadControlValues(
            leftX: stick(.leftX), leftY: -stick(.leftY),
            rightX: stick(.rightX), rightY: -stick(.rightY),
            leftTrigger: Float(values[.leftTrigger]!) / 1023,
            rightTrigger: Float(values[.rightTrigger]!) / 1023,
            sprint: pressed(14) || pressed(15), buttons: buttons)
    }
}

struct HIDGamepadControlValues: Equatable, Sendable {
    var leftX: Float
    var leftY: Float
    var rightX: Float
    var rightY: Float
    var leftTrigger: Float
    var rightTrigger: Float
    var sprint: Bool
    var buttons: UInt8
}

/// A connection starts empty and cannot drive anything until all whitelisted
/// controls have been read and released. Seed reads and callbacks use this same
/// validator; missing values are never guessed to mean neutral.
struct HIDGamepadValueState: Sendable {
    let profile: HIDGamepadProfile
    private var values: [HIDGamepadChannel: Int] = [:]
    private var observedNeutral = false

    init(profile: HIDGamepadProfile = .xboxWirelessBLE) { self.profile = profile }

    var isComplete: Bool { Set(values.keys) == profile.channels }
    var missingChannels: Set<HIDGamepadChannel> { profile.channels.subtracting(values.keys) }

    var isNeutral: Bool {
        profile.isNeutral(values)
    }

    var output: HIDGamepadControlValues? { observedNeutral ? normalized : nil }

    @discardableResult
    mutating func update(channel: HIDGamepadChannel, rawValue: Int) -> Bool {
        guard profile.accepts(rawValue: rawValue, for: channel) else {
            reset()
            return false
        }
        values[channel] = rawValue
        if isNeutral { observedNeutral = true }
        return true
    }

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
        observedNeutral = false
    }

    private var normalized: HIDGamepadControlValues? {
        profile.normalized(values)
    }
}

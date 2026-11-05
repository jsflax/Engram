import Darwin
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

enum HIDGamepadInputStatus: String, Codable, Sendable, Equatable {
    case inactive, absent, ambiguous, permissionRequired, unsupported
    case connecting, awaitingNeutral, ready, failed
}

struct HIDGamepadInputSnapshot: Sendable {
    let state: GamepadInputState?
    let status: HIDGamepadInputStatus
}

/// A profile-based HID fallback when GameController supplies no extended
/// profile. The caller owns foreground/focus and backend selection.
/// This type never requests Input Monitoring access or changes OS settings.
final class HIDGamepadInputProvider: @unchecked Sendable {
    private let mailbox = HIDGamepadInputMailbox()
    private let worker: HIDGamepadInputWorker

    init(profiles: [HIDGamepadProfile] = [.xboxWirelessBLE]) {
        worker = HIDGamepadInputWorker(mailbox: mailbox, profiles: profiles)
    }

    /// Cheap on every frame: only transitions enqueue work. Turning off clears
    /// the published state synchronously, before an asynchronous HID cancel.
    func setActive(_ active: Bool) {
        guard mailbox.setActive(active) else { return }
        let worker = worker
        worker.queue.async { worker.reconcile() }
    }

    func snapshot() -> HIDGamepadInputSnapshot { mailbox.snapshot() }

    func stop() {
        guard mailbox.stop() else { return }
        let worker = worker
        worker.queue.async { worker.reconcile() }
    }

    deinit { stop() }
}

private final class HIDGamepadInputIdentity: Sendable {}

/// The only cross-queue storage. No IOKit object crosses this lock. Retaining
/// the last identity even while inactive prevents its address being reused
/// before a replacement is allocated; connectionGeneration also distinguishes
/// attachments if a disconnect/reconnect occurs between scene frames.
private final class HIDGamepadInputMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var identity = HIDGamepadInputIdentity()
    private var published = HIDGamepadInputSnapshot(state: nil, status: .inactive)

    func setActive(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, active != value else { return false }
        active = value
        generation &+= 1
        published = HIDGamepadInputSnapshot(state: nil, status: value ? .connecting : .inactive)
        return true
    }

    func stop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        stopped = true; active = false; generation &+= 1
        published = HIDGamepadInputSnapshot(state: nil, status: .inactive)
        return true
    }

    func activeGeneration() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return active && !stopped ? generation : nil
    }

    func snapshot() -> HIDGamepadInputSnapshot {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    func publish(generation expected: UInt64, status: HIDGamepadInputStatus,
                 controls: HIDGamepadControlValues? = nil,
                 identity token: HIDGamepadInputIdentity? = nil,
                 connectionGeneration: UInt64 = 0) {
        lock.lock(); defer { lock.unlock() }
        guard active, !stopped, generation == expected else { return }
        if let token { identity = token }
        let state: GamepadInputState?
        if let controls {
            var input = GamepadInputState(identity: ObjectIdentifier(identity))
            input.connectionGeneration = connectionGeneration
            input.leftX = controls.leftX; input.leftY = controls.leftY
            input.rightX = controls.rightX; input.rightY = controls.rightY
            input.leftTrigger = controls.leftTrigger; input.rightTrigger = controls.rightTrigger
            input.sprint = controls.sprint
            input.buttons = .init(rawValue: controls.buttons)
            state = input
        } else { state = nil }
        published = HIDGamepadInputSnapshot(state: state, status: status)
    }
}

/// Mutable HID state is confined to this serial queue, including permission
/// checks, registry discovery, descriptor reads, initial values and close.
private final class HIDGamepadInputWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.engram.controller.hid", qos: .utility)
    let mailbox: HIDGamepadInputMailbox
    let profiles: [HIDGamepadProfile]
    private var timer: DispatchSourceTimer?
    private var connection: HIDGamepadConnection?
    private var connectionSerial: UInt64 = 0
    private var nextDiscovery: TimeInterval = 0
    private var nextRegistryCheck: TimeInterval = 0

    init(mailbox: HIDGamepadInputMailbox, profiles: [HIDGamepadProfile]) {
        self.mailbox = mailbox
        self.profiles = profiles
    }

    func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let generation = mailbox.activeGeneration() else {
            timer?.cancel(); timer = nil
            cancelConnection()
            return
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(250),
                           repeating: .milliseconds(250), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
        if let connection, connection.generation != generation {
            nextDiscovery = 0; nextRegistryCheck = 0
            cancelConnection()
        } else if connection == nil {
            nextDiscovery = 0; nextRegistryCheck = 0
            poll()
        }
    }

    private func poll() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let generation = mailbox.activeGeneration() else { reconcile(); return }
        if let connection, connection.generation != generation {
            cancelConnection(); return
        }
        guard connection?.cancelling != true else { return }

        // CopyMatchingElements can itself open a user client. The permission
        // check must precede creation and ALL descriptor/device APIs, not just
        // the explicit Open below. Registry properties alone need no such open.
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if connection != nil && access != kIOHIDAccessTypeGranted {
            fail(.permissionRequired, generation: generation); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Permission liveness is checked at 250 ms while active. The more
        // expensive registry and descriptor work remains bounded to 5 seconds.
        guard now >= nextRegistryCheck else { return }
        nextRegistryCheck = now + 5
        guard let services = matchingServices() else {
            fail(.failed, generation: generation); return
        }
        defer { services.forEach { IOObjectRelease($0.service) } }
        guard services.count == 1 else {
            fail(services.isEmpty ? .absent : .ambiguous, generation: generation); return
        }
        guard access == kIOHIDAccessTypeGranted else {
            fail(.permissionRequired, generation: generation); return
        }
        if let connection {
            guard connection.registryID == services[0].registryID else {
                fail(.connecting, generation: generation)
                nextDiscovery = 0; nextRegistryCheck = 0
                return
            }
            // Missing seed values can be retried without guessing neutral.
            if !connection.values.isComplete { seed(connection, onlyMissing: true) }
            publish(connection)
            return
        }
        guard now >= nextDiscovery, mailbox.activeGeneration() == generation else { return }
        nextDiscovery = now + 5
        let profile = services[0].profile
        // Registry enumeration can outlast a permission change. Recheck at the
        // boundary of each operation that may create/open a HID user client.
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            mailbox.publish(generation: generation, status: .permissionRequired); return
        }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, services[0].service) else {
            mailbox.publish(generation: generation, status: .failed); return
        }
        guard mailbox.activeGeneration() == generation,
              IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            mailbox.publish(generation: generation, status: .permissionRequired); return
        }
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement],
              elements.count <= 512 else {
            mailbox.publish(generation: generation, status: .failed); return
        }
        let inputElements = elements.filter {
            (1...4).contains(IOHIDElementGetType($0).rawValue)
                && profile.inputReportIDs.contains(IOHIDElementGetReportID($0))
        }
        let descriptors = inputElements.map(Self.describe)
        guard let selectedInputs = profile.selectedInputs(in: descriptors) else {
            mailbox.publish(generation: generation, status: .unsupported); return
        }
        var allowed: [IOHIDElementCookie: HIDGamepadElementRecord] = [:]
        // The complete descriptor list may contain recognized auxiliary fields.
        // Only the profile's selected gamepad controls enter matching or reads.
        for selected in selectedInputs {
            let element = inputElements[selected.index]
            let descriptor = descriptors[selected.index]
            let cookie = IOHIDElementGetCookie(element)
            guard allowed[cookie] == nil else {
                mailbox.publish(generation: generation, status: .unsupported); return
            }
            allowed[cookie] = HIDGamepadElementRecord(element: element, descriptor: descriptor, channel: selected.channel)
        }
        guard allowed.count == profile.channels.count, mailbox.activeGeneration() == generation,
              IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            mailbox.publish(generation: generation, status: .permissionRequired); return
        }
        let matching: [[String: Any]] = allowed.map { cookie, entry in
            [kIOHIDElementCookieKey: cookie, kIOHIDElementReportIDKey: entry.descriptor.reportID,
             kIOHIDElementUsagePageKey: entry.descriptor.page, kIOHIDElementUsageKey: entry.descriptor.usage]
        }
        IOHIDDeviceSetInputValueMatchingMultiple(device, matching as CFArray)
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            mailbox.publish(generation: generation, status: .failed); return
        }
        connectionSerial &+= 1
        let connection = HIDGamepadConnection(device: device, allowed: allowed, profile: profile,
                                               registryID: services[0].registryID,
                                               generation: generation, serial: connectionSerial,
                                               owner: self)
        self.connection = connection
        // Keep the callback context alive until the dispatch cancel handler;
        // unretained C callbacks are never allowed to outlive this ownership.
        let context = Unmanaged.passRetained(connection).toOpaque()
        let contextAddress = UInt(bitPattern: context)
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
            guard let context else { return }
            let connection = Unmanaged<HIDGamepadConnection>.fromOpaque(context).takeUnretainedValue()
            connection.owner?.receive(connection, result: result, value: value)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            let connection = Unmanaged<HIDGamepadConnection>.fromOpaque(context).takeUnretainedValue()
            connection.owner?.removed(connection)
        }, context)
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceSetCancelHandler(device) {
            let pointer = UnsafeMutableRawPointer(bitPattern: contextAddress)!
            let connection = Unmanaged<HIDGamepadConnection>.fromOpaque(pointer).takeRetainedValue()
            IOHIDDeviceClose(connection.device, IOOptionBits(kIOHIDOptionsTypeNone))
            connection.owner?.didCancel(connection)
        }
        connection.acceptEventsAfter = mach_absolute_time()
        IOHIDDeviceActivate(device)
        seed(connection, onlyMissing: false)
        publish(connection)
        if mailbox.activeGeneration() != generation { cancelConnection() }
    }

    private func matchingServices() -> [(service: io_service_t, profile: HIDGamepadProfile, registryID: UInt64)]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var matches: [(service: io_service_t, profile: HIDGamepadProfile, registryID: UInt64)] = []
        var count = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            count += 1
            guard count <= 512 else { matches.forEach { IOObjectRelease($0.service) }; return nil }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let vendor = property("VendorID") as? Int,
                  let product = property("ProductID") as? Int,
                  let page = property("PrimaryUsagePage") as? Int,
                  let usage = property("PrimaryUsage") as? Int,
                  let transport = property("Transport") as? String else { continue }
            for profile in profiles where profile.matchesDevice(vendor: vendor, product: product,
                    usagePage: page, usage: usage, transport: transport) {
                var registryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
                    matches.forEach { IOObjectRelease($0.service) }; return nil
                }
                guard IOObjectRetain(service) == KERN_SUCCESS else {
                    matches.forEach { IOObjectRelease($0.service) }; return nil
                }
                matches.append((service, profile, registryID))
            }
        }
        return matches
    }

    private static func describe(_ element: IOHIDElement) -> HIDGamepadElementDescriptor {
        var parent = IOHIDElementGetParent(element)
        var gamepad = false, prohibited = false, depth = 0
        while let ancestor = parent {
            depth += 1
            if depth > 16 { prohibited = true; break }
            if IOHIDElementGetType(ancestor) == kIOHIDElementTypeCollection,
               IOHIDElementGetUsagePage(ancestor) == 1 {
                let usage = IOHIDElementGetUsage(ancestor)
                gamepad = gamepad || usage == 5
                prohibited = prohibited || usage == 2 || usage == 6
            }
            parent = IOHIDElementGetParent(ancestor)
        }
        return HIDGamepadElementDescriptor(reportID: IOHIDElementGetReportID(element),
            type: IOHIDElementGetType(element).rawValue,
            page: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element),
            minimum: IOHIDElementGetLogicalMin(element), maximum: IOHIDElementGetLogicalMax(element),
            isRelative: IOHIDElementIsRelative(element), hasGamepadAncestor: gamepad,
            hasKeyboardOrMouseAncestor: prohibited,
            reportSize: IOHIDElementGetReportSize(element), reportCount: IOHIDElementGetReportCount(element))
    }

    private func seed(_ connection: HIDGamepadConnection, onlyMissing: Bool) {
        guard !connection.cancelling, mailbox.activeGeneration() == connection.generation else { return }
        for entry in connection.allowed.values {
            if onlyMissing && !connection.values.missingChannels.contains(entry.channel) { continue }
            let value: IOHIDValue? = withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { output in
                guard IOHIDDeviceGetValue(connection.device, entry.element, output.baseAddress!) == kIOReturnSuccess else { return nil }
                return output[0].takeUnretainedValue()
            }
            guard let value else { continue }
            guard validate(connection, value: value, expected: entry.channel) else { continue }
            guard connection.values.update(channel: entry.channel, rawValue: IOHIDValueGetIntegerValue(value)) else {
                fail(.failed, generation: connection.generation); return
            }
        }
    }

    private func validate(_ connection: HIDGamepadConnection, value: IOHIDValue,
                          expected: HIDGamepadChannel? = nil) -> Bool {
        guard !connection.cancelling, mailbox.activeGeneration() == connection.generation else { return false }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetDevice(element) === connection.device,
              let entry = connection.allowed[IOHIDElementGetCookie(element)],
              Self.describe(element) == entry.descriptor,
              expected == nil || expected == entry.channel else { return false }
        return true
    }

    private func receive(_ connection: HIDGamepadConnection, result: IOReturn, value: IOHIDValue) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.connection === connection, !connection.cancelling,
              mailbox.activeGeneration() == connection.generation else { return }
        guard result == kIOReturnSuccess else { fail(.failed, generation: connection.generation); return }
        guard validate(connection, value: value),
              IOHIDValueGetTimeStamp(value) > connection.acceptEventsAfter else { return }
        if !connection.hasFreshInput {
            // An initial cached neutral value alone cannot arm the fallback.
            // A fresh report first refreshes every validated element, including
            // unchanged buttons that never generate their own callbacks.
            connection.values.reset()
            connection.hasFreshInput = true
            seed(connection, onlyMissing: false)
        }
        guard !connection.cancelling,
              let entry = connection.allowed[IOHIDElementGetCookie(IOHIDValueGetElement(value))] else { return }
        guard connection.values.update(channel: entry.channel, rawValue: IOHIDValueGetIntegerValue(value)) else {
            fail(.failed, generation: connection.generation); return
        }
        publish(connection)
    }

    private func publish(_ connection: HIDGamepadConnection) {
        guard !connection.cancelling else { return }
        let controls = connection.hasFreshInput ? connection.values.output : nil
        mailbox.publish(generation: connection.generation,
                        status: controls == nil ? .awaitingNeutral : .ready,
                        controls: controls, identity: connection.identity,
                        connectionGeneration: connection.serial)
    }

    private func fail(_ status: HIDGamepadInputStatus, generation: UInt64) {
        mailbox.publish(generation: generation, status: status)
        nextDiscovery = ProcessInfo.processInfo.systemUptime + 5
        cancelConnection()
    }

    private func removed(_ connection: HIDGamepadConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.connection === connection else { return }
        fail(.absent, generation: connection.generation)
    }

    private func cancelConnection() {
        guard let connection, !connection.cancelling else { return }
        connection.cancelling = true
        connection.values.reset()
        IOHIDDeviceCancel(connection.device)
    }

    private func didCancel(_ connection: HIDGamepadConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.connection === connection else { return }
        self.connection = nil
        if let generation = mailbox.activeGeneration(), generation != connection.generation { reconcile() }
    }
}

private struct HIDGamepadElementRecord {
    let element: IOHIDElement
    let descriptor: HIDGamepadElementDescriptor
    let channel: HIDGamepadChannel
}

/// Every field is confined to the owning worker's dispatch queue. IOKit keeps
/// one explicit retained context until its cancellation handler has finished.
private final class HIDGamepadConnection: @unchecked Sendable {
    let device: IOHIDDevice
    let allowed: [IOHIDElementCookie: HIDGamepadElementRecord]
    let generation: UInt64
    let serial: UInt64
    let registryID: UInt64
    let identity = HIDGamepadInputIdentity()
    weak var owner: HIDGamepadInputWorker?
    var cancelling = false
    var acceptEventsAfter: UInt64 = 0
    var hasFreshInput = false
    var values: HIDGamepadValueState

    init(device: IOHIDDevice, allowed: [IOHIDElementCookie: HIDGamepadElementRecord],
         profile: HIDGamepadProfile, registryID: UInt64,
         generation: UInt64, serial: UInt64, owner: HIDGamepadInputWorker) {
        self.device = device; self.allowed = allowed
        self.generation = generation; self.serial = serial; self.owner = owner
        self.registryID = registryID
        self.values = HIDGamepadValueState(profile: profile)
    }
}

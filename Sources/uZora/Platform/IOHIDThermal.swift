import Foundation
import IOKit

/// Reads Apple Silicon temperature sensors via the private
/// `IOHIDEventSystemClient` API (the `AppleARMPMUTempSensor` family exposed
/// as HID temperature sensors: PrimaryUsagePage `0xff00` / Usage `0x0005`).
///
/// This is the mechanism used by open-source tools (Stats, macmon) to read
/// on-die temperatures on Apple Silicon, where the legacy SMC `Tp*` keys are
/// unreliable (denormal / crosstalk garbage) and `powermetrics` no longer
/// exposes an `smc` sampler or any die temperature.
///
/// Read-only, no entitlement, verified to work under ad-hoc signing on
/// macOS 26 / Apple Silicon. The symbols are private (no public headers),
/// declared here via `@_silgen_name` and resolved at link time against
/// `IOKit.framework`.
///
/// Concurrency: stateless. Each call creates a fresh client and releases
/// every Create/Copy result via `Unmanaged.takeRetainedValue()` — safe to
/// call from a 10-second-polled probe without leaking.
public enum IOHIDThermal {

    // MARK: - Private IOKit/IOHID symbols (resolved from IOKit.framework)

    public typealias EventSystemClient = CFTypeRef
    public typealias ServiceClient = CFTypeRef
    public typealias HIDEvent = CFTypeRef

    @_silgen_name("IOHIDEventSystemClientCreate")
    private static func _create(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?

    @_silgen_name("IOHIDEventSystemClientSetMatching")
    private static func _setMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32

    @_silgen_name("IOHIDEventSystemClientCopyServices")
    private static func _copyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?

    @_silgen_name("IOHIDServiceClientCopyProperty")
    private static func _copyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?

    @_silgen_name("IOHIDServiceClientCopyEvent")
    private static func _copyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<CFTypeRef>?

    @_silgen_name("IOHIDEventGetFloatValue")
    private static func _getFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

    // MARK: - Constants (from the private IOHIDEventTypes.h)

    /// `kIOHIDEventTypeTemperature`.
    private static let kEventTypeTemperature: Int64 = 15
    /// Field selector = `IOHIDEventFieldBase(type)` = `type << 16`.
    private static let temperatureField = Int32(truncatingIfNeeded: kEventTypeTemperature << 16)
    /// `kHIDPage_AppleVendor`.
    private static let appleVendorUsagePage = 0xff00
    /// `kHIDUsage_AppleVendor_TemperatureSensor`.
    private static let temperatureSensorUsage = 0x0005

    // MARK: - Public API

    /// A single named temperature reading, in °C.
    public struct Reading: Sendable, Equatable {
        public let name: String
        public let tempC: Double
        public init(name: String, tempC: Double) {
            self.name = name
            self.tempC = tempC
        }
    }

    /// Read every HID temperature sensor reporting a positive value.
    /// Returns an empty array where the sensors are absent (VMs, future
    /// hardware) — callers should treat empty as "abstain".
    public static func readSensors() -> [Reading] {
        guard let client = _create(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        let matching: [String: Any] = [
            "PrimaryUsagePage": appleVendorUsagePage,
            "PrimaryUsage": temperatureSensorUsage,
        ]
        _ = _setMatching(client, matching as CFDictionary)

        guard let servicesCF = _copyServices(client)?.takeRetainedValue() else { return [] }
        let services = servicesCF as [ServiceClient]

        var out: [Reading] = []
        out.reserveCapacity(services.count)
        for svc in services {
            let name = (_copyProperty(svc, "Product" as CFString)?.takeRetainedValue() as? String) ?? "?"
            guard let event = _copyEvent(svc, kEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let t = _getFloatValue(event, temperatureField)
            // Parked / non-reporting sensors return ~0 — skip so they do not
            // drag an average down.
            if t.isFinite, t > 1.0 {
                out.append(Reading(name: name, tempC: t))
            }
        }
        return out
    }
}

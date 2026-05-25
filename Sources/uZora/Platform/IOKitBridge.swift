import Foundation
import IOKit
import IOKit.ps
import os

/// Shared helpers for IOKit / SMC user-space access.
///
/// All entry points are read-only on user-space-accessible registries
/// (AppleSMC keys, IOPMPowerSource, IOPSPowerSources, IOBlockStorageDriver
/// statistics). No privileged helper, no entitlements beyond the App
/// Sandbox baseline (and most of these work *outside* the sandbox too).
///
/// Concurrency: this enum is stateless. Each helper opens a fresh
/// `io_connect_t` / `CFDictionary` and releases it before returning.
/// Callers may invoke from any task / actor.
public enum IOKitBridge {

    static let log = Logger(
        subsystem: "place.unicorns.uzora",
        category: "iokit-bridge"
    )

    // MARK: - SMC (AppleSMC user client)

    /// SMC key data type tag (FourCC) returned by the controller.
    ///
    /// The SMC firmware returns the type for each key so callers know
    /// how to interpret the raw bytes. Only the types relevant to the
    /// Phase 2 probes are listed; extend as needed.
    public enum SMCKeyType: String {
        /// 4-byte float, big-endian, as used by `F0Ac` (fan RPM).
        case flt = "flt "
        /// 16.16 fixed-point, signed, used by some thermal keys.
        case sp78 = "sp78"
        /// 32-bit unsigned int, big-endian.
        case ui32 = "ui32"
        /// 16-bit unsigned int, big-endian.
        case ui16 = "ui16"
        /// 8-bit unsigned int.
        case ui8  = "ui8 "
        /// Free-form byte buffer.
        case ch8s = "ch8s"
    }

    /// Decoded value of a single SMC key read.
    public struct SMCKeyValue: Sendable {
        public let key: String
        public let type: String
        public let dataSize: UInt32
        public let bytes: [UInt8]

        /// Interprets the raw bytes as a 32-bit big-endian IEEE-754 float.
        public var asFloat: Float? {
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) << 24
                   | UInt32(bytes[1]) << 16
                   | UInt32(bytes[2]) <<  8
                   | UInt32(bytes[3])
            return Float(bitPattern: raw)
        }

        /// Interprets the raw bytes as an `sp78` (signed 16.16) fixed-point.
        public var asSP78: Double? {
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        }

        /// Interprets the raw bytes as a big-endian unsigned int (≤ 4 bytes).
        public var asUInt: UInt32? {
            guard !bytes.isEmpty, bytes.count <= 4 else { return nil }
            var value: UInt32 = 0
            for byte in bytes.prefix(4) {
                value = (value << 8) | UInt32(byte)
            }
            return value
        }
    }

    /// SMC user-client command codes (from open-source AppleSMC headers).
    private enum SMCCommand: UInt8 {
        case readKey      = 5
        case readKeyInfo  = 9
    }

    /// AppleSMC user-client selector for the `IOConnectCallStructMethod`.
    private static let smcSelector: UInt32 = 2

    /// Internal structure understood by the AppleSMC user client.
    ///
    /// Layout matches the reverse-engineered AppleSMC.kext interface
    /// documented in projects like `smckit`, `iSMC`, `powermetrics` and
    /// `smcFanControl`. We only fill the fields we need (`key`, `data8`,
    /// `keyInfo.dataSize`, `keyInfo.dataType`).
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8) = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0)
    }

    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// Encode a 4-char SMC key string (e.g. "F0Ac") to its UInt32 form.
    private static func encodeKey(_ key: String) -> UInt32? {
        let chars = Array(key.utf8)
        guard chars.count == 4 else { return nil }
        return UInt32(chars[0]) << 24
             | UInt32(chars[1]) << 16
             | UInt32(chars[2]) <<  8
             | UInt32(chars[3])
    }

    /// Decode a UInt32 FourCC back to its 4-char string form.
    private static func decodeFourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >>  8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Open a fresh connection to the `AppleSMC` user client.
    ///
    /// The caller MUST `IOServiceClose` the returned `io_connect_t` when
    /// done. Returns `nil` if the SMC service is unavailable (e.g. virtual
    /// machines, future hardware revisions that ship without SMC).
    public static func openSMC() -> io_connect_t? {
        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            log.debug("AppleSMC service not found")
            return nil
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else {
            log.error("IOServiceOpen(AppleSMC) failed: kr=\(kr)")
            return nil
        }
        return conn
    }

    /// Read a single SMC key from an already-open connection.
    ///
    /// Two-step protocol: first ask for the key's `dataSize`/`dataType`
    /// (`SMCCommand.readKeyInfo`), then ask for the bytes (`SMCCommand.readKey`).
    public static func readSMCKey(_ key: String, conn: io_connect_t) -> SMCKeyValue? {
        guard let encoded = encodeKey(key) else {
            log.error("invalid SMC key: \(key)")
            return nil
        }

        // Step 1: query key info.
        var info = SMCParamStruct()
        info.key = encoded
        info.data8 = SMCCommand.readKeyInfo.rawValue

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size

        let krInfo = withUnsafePointer(to: &info) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(
                    conn,
                    smcSelector,
                    inPtr,
                    MemoryLayout<SMCParamStruct>.size,
                    outPtr,
                    &outputSize
                )
            }
        }
        guard krInfo == KERN_SUCCESS, output.result == 0 else {
            log.debug("SMC readKeyInfo(\(key)) failed: kr=\(krInfo), result=\(output.result)")
            return nil
        }

        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType
        guard dataSize > 0, dataSize <= 32 else {
            log.debug("SMC key \(key) reported odd dataSize=\(dataSize)")
            return nil
        }

        // Step 2: read the key bytes.
        var read = SMCParamStruct()
        read.key = encoded
        read.keyInfo.dataSize = dataSize
        read.data8 = SMCCommand.readKey.rawValue

        var readOut = SMCParamStruct()
        outputSize = MemoryLayout<SMCParamStruct>.size

        let krRead = withUnsafePointer(to: &read) { inPtr in
            withUnsafeMutablePointer(to: &readOut) { outPtr in
                IOConnectCallStructMethod(
                    conn,
                    smcSelector,
                    inPtr,
                    MemoryLayout<SMCParamStruct>.size,
                    outPtr,
                    &outputSize
                )
            }
        }
        guard krRead == KERN_SUCCESS, readOut.result == 0 else {
            log.debug("SMC readKey(\(key)) failed: kr=\(krRead), result=\(readOut.result)")
            return nil
        }

        // Copy the bytes tuple into a real array.
        var buf = [UInt8](repeating: 0, count: Int(dataSize))
        withUnsafeBytes(of: readOut.bytes) { rawBuf in
            for i in 0..<Int(dataSize) {
                buf[i] = rawBuf[i]
            }
        }

        return SMCKeyValue(
            key: key,
            type: decodeFourCC(dataType),
            dataSize: dataSize,
            bytes: buf
        )
    }

    /// Close an SMC connection opened with `openSMC()`.
    public static func closeSMC(_ conn: io_connect_t) {
        IOServiceClose(conn)
    }

    /// Convenience: open SMC, read a single key, close. Suitable for
    /// one-shot diagnostics; for batch reads (e.g. fan probe), keep the
    /// connection open across calls.
    public static func readSMCKeyOneShot(_ key: String) -> SMCKeyValue? {
        guard let conn = openSMC() else { return nil }
        defer { closeSMC(conn) }
        return readSMCKey(key, conn: conn)
    }

    // MARK: - IOService walking

    /// Iterate all services matching a class name, calling `body` for each.
    /// The iterator handle is owned and released by this helper.
    public static func forEachMatchingService(
        className: String,
        _ body: (io_object_t) -> Void
    ) {
        let matching = IOServiceMatching(className)
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard kr == KERN_SUCCESS else {
            log.debug("IOServiceGetMatchingServices(\(className)) kr=\(kr)")
            return
        }
        defer { IOObjectRelease(iter) }

        while case let svc = IOIteratorNext(iter), svc != 0 {
            body(svc)
            IOObjectRelease(svc)
        }
    }

    /// Copy a single property from a service registry entry.
    public static func copyProperty<T>(
        _ service: io_object_t,
        key: String,
        as type: T.Type = T.self
    ) -> T? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let unwrapped = cf.takeRetainedValue()
        return unwrapped as? T
    }

    /// Copy the entire property dictionary for a service entry (recurse=false).
    public static func copyProperties(_ service: io_object_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = props?.takeRetainedValue() else {
            return nil
        }
        return dict as? [String: Any]
    }

    /// Walk parents of `service` via the IOService plane until a parent
    /// matching `className` is found (or root is reached).
    public static func findParent(
        of service: io_object_t,
        matching className: String
    ) -> io_object_t? {
        var current = service
        IOObjectRetain(current)
        while true {
            var parent: io_object_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS, parent != 0 else { return nil }

            if IOObjectConformsTo(parent, className) != 0 {
                return parent
            }
            current = parent
        }
    }
}

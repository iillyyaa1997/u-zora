import Foundation
import Testing
@testable import uZora

/// Pure-function coverage for the gated Tier-B `/bin/ps` attribution bridge.
/// All parse/classification/selection logic is exercised with fixtures; the
/// single impure `snapshotViaPS()` gets only one tolerant non-crash smoke.
@Suite("ProcessAttribution — parse / classify / select")
struct ProcessAttributionTests {

    // MARK: - parseCPUTime — every ps TIME shape

    @Test func parseCPUTime_secondsOnly() {
        #expect(ProcessAttribution.parseCPUTime("0.00") == 0.0)
        #expect(ProcessAttribution.parseCPUTime("12.34") == 12.34)
        #expect(ProcessAttribution.parseCPUTime("59.99") == 59.99)
    }

    @Test func parseCPUTime_minutesSeconds() {
        // MM:SS.ss
        #expect(ProcessAttribution.parseCPUTime("01:30.00") == 90.0)
        let mmss: Double = 59 * 60 + 43.51
        #expect(ProcessAttribution.parseCPUTime("59:43.51") == mmss)
        #expect(ProcessAttribution.parseCPUTime("00:01.00") == 1.0)
    }

    @Test func parseCPUTime_hoursMinutesSeconds() {
        // HH:MM:SS and HH:MM:SS.ss
        #expect(ProcessAttribution.parseCPUTime("01:00:00") == 3600.0)
        let hms: Double = 2 * 3600 + 3 * 60 + 4
        #expect(ProcessAttribution.parseCPUTime("02:03:04") == hms)
        let v = ProcessAttribution.parseCPUTime("59:43:51.00")
        let hmsFrac: Double = 59 * 3600 + 43 * 60 + 51
        #expect(v == hmsFrac)
    }

    @Test func parseCPUTime_dayPrefixed() {
        // D-HH:MM:SS — ps emits days as a "D-" prefix for long-lived procs.
        #expect(ProcessAttribution.parseCPUTime("1-00:00:00") == 86_400.0)
        let dhms: Double = 2 * 86_400 + 1 * 3600 + 2 * 60 + 3
        #expect(ProcessAttribution.parseCPUTime("2-01:02:03") == dhms)
        #expect(ProcessAttribution.parseCPUTime("0-00:00:10") == 10.0)
    }

    @Test func parseCPUTime_garbageReturnsNil() {
        #expect(ProcessAttribution.parseCPUTime("") == nil)
        #expect(ProcessAttribution.parseCPUTime("abc") == nil)
        #expect(ProcessAttribution.parseCPUTime("12:ab") == nil)
        #expect(ProcessAttribution.parseCPUTime("1:2:3:4") == nil)   // 4 colon-fields
        #expect(ProcessAttribution.parseCPUTime("x-01:02:03") == nil) // bad day part
        #expect(ProcessAttribution.parseCPUTime("-5.0") == nil)       // empty day part
    }

    @Test func parseCPUTime_handlesWhitespace() {
        #expect(ProcessAttribution.parseCPUTime("  12.34  ") == 12.34)
    }

    // MARK: - isSystemPath

    @Test func isSystemPath_systemPrefixes() {
        #expect(ProcessAttribution.isSystemPath("/System/Library/CoreServices/ecosystemd"))
        #expect(ProcessAttribution.isSystemPath("/usr/libexec/secinitd"))
        #expect(ProcessAttribution.isSystemPath("/usr/sbin/cfprefsd"))
    }

    @Test func isSystemPath_userAndUsrBinAreNotSystem() {
        #expect(!ProcessAttribution.isSystemPath("/usr/bin/python3"))     // user tool dir
        #expect(!ProcessAttribution.isSystemPath("/Applications/Lens.app/Contents/MacOS/Lens"))
        #expect(!ProcessAttribution.isSystemPath("/opt/homebrew/bin/node"))
        #expect(!ProcessAttribution.isSystemPath("/usr/local/bin/foo"))
        #expect(!ProcessAttribution.isSystemPath(""))
    }

    // MARK: - isSuppressed

    @Test func isSuppressed_indexingAndBackupFamily() {
        for name in ["mds", "mds_stores", "mdworker", "mdworker_shared",
                     "mdbulkimport", "backupd", "backupd-helper", "Spotlight"] {
            #expect(ProcessAttribution.isSuppressed(command: name), "\(name) should be suppressed")
        }
    }

    @Test func isSuppressed_doesNotSuppressSeedCulprits() {
        // The whole point: ecosystem daemons are NEVER suppressed.
        #expect(!ProcessAttribution.isSuppressed(command: "ecosystemd"))
        #expect(!ProcessAttribution.isSuppressed(command: "ecosystemanalyticsd"))
        #expect(!ProcessAttribution.isSuppressed(command: "WindowServer"))
        #expect(!ProcessAttribution.isSuppressed(command: "node"))
    }

    // MARK: - parse(psOutput:)

    /// Mirrors `ps -axo pid=,uid=,time=,comm=` (no header; comm = full path).
    private let fixture = """
    13579 0 59:43:51 /System/Library/PrivateFrameworks/Ecosystem.framework/Versions/A/Support/ecosystemd
    635 88 68:57:26 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
    94914 0 15:06:02 /System/Library/PrivateFrameworks/EcosystemAnalytics.framework/Support/ecosystemanalyticsd
    501 501 1:23.45 /Applications/Warp.app/Contents/MacOS/stable
    77 0 2-03:04:05 /usr/libexec/mds_stores
    88 0 00:30.00 /opt/homebrew/bin/node
    garbage line with too few
    999 notanumber 00:01.00 /usr/sbin/cfprefsd
    """

    @Test func parse_classifiesAndComputesFields() {
        let procs = ProcessAttribution.parse(psOutput: fixture)
        // 6 valid rows: ecosystemd, WindowServer, ecosystemanalyticsd, Warp
        // stable, mds_stores, node. (garbage + bad-uid lines skipped.)
        #expect(procs.count == 6)

        let byCommand = Dictionary(uniqueKeysWithValues: procs.map { ($0.command, $0) })

        let eco = byCommand["ecosystemd"]
        #expect(eco?.pid == 13579)
        #expect(eco?.uid == 0)
        #expect(eco?.isSystem == true)
        // TIME "59:43:51" is HH:MM:SS form → 59h 43m 51s.
        let ecoExpected: Double = 59 * 3600 + 43 * 60 + 51
        #expect(abs((eco?.cpuSeconds ?? 0) - ecoExpected) < 0.001)

        let ws = byCommand["WindowServer"]
        #expect(ws?.uid == 88)
        #expect(ws?.isSystem == true)

        let warp = byCommand["stable"]
        #expect(warp?.isSystem == false) // /Applications → user
        #expect(warp?.uid == 501)

        let node = byCommand["node"]
        #expect(node?.isSystem == false) // /opt/homebrew → user

        let mds = byCommand["mds_stores"]
        #expect(mds?.isSystem == true)   // /usr/libexec → system
        let mdsExpected: Double = 2 * 86_400 + 3 * 3600 + 4 * 60 + 5
        #expect(abs((mds?.cpuSeconds ?? 0) - mdsExpected) < 0.001)
    }

    @Test func parse_skipsMalformedLines() {
        // The "garbage line with too few" + "notanumber" uid rows must be gone.
        let procs = ProcessAttribution.parse(psOutput: fixture)
        #expect(!procs.contains { $0.command == "cfprefsd" }) // bad uid → skipped
        #expect(!procs.contains { $0.pid == 0 })
    }

    @Test func parse_emptyAndBlankInput() {
        #expect(ProcessAttribution.parse(psOutput: "").isEmpty)
        #expect(ProcessAttribution.parse(psOutput: "\n  \n\n").isEmpty)
    }

    // MARK: - topSystemOffender

    @Test func topSystemOffender_picksHighestQualifyingSystemProc() {
        let procs = ProcessAttribution.parse(psOutput: fixture)
        // All fixture TIME columns are HH:MM:SS form. Among NON-suppressed
        // SYSTEM procs over the 600s floor:
        //   WindowServer "68:57:26" = 248246 s  (largest, system, not suppressed)
        //   ecosystemd   "59:43:51" = 215031 s
        //   ecosystemanalyticsd "15:06:02" = 54362 s
        //   mds_stores   "2-03:04:05" = 184k s but SUPPRESSED → excluded
        //   Warp/node are USER → excluded
        let offender = ProcessAttribution.topSystemOffender(procs, minCPUSeconds: 600)
        let off = offender
        #expect(off?.command == "WindowServer")
    }

    @Test func topSystemOffender_skipsSuppressedUserAndSubThreshold() {
        // Only a suppressed system proc + a user proc + a sub-threshold system
        // proc → no qualifying offender.
        let lines = """
        1 0 10-00:00:00 /usr/libexec/mds_stores
        2 501 99:00:00 /Applications/Foo.app/Contents/MacOS/Foo
        3 0 00:05.00 /System/Library/CoreServices/tinyd
        """
        let procs = ProcessAttribution.parse(psOutput: lines)
        // mds_stores suppressed; Foo is user; tinyd = 5s < 600 floor.
        #expect(ProcessAttribution.topSystemOffender(procs, minCPUSeconds: 600) == nil)
    }

    @Test func topSystemOffender_picksMaxAmongQualifying() {
        let lines = """
        1 0 20:00 /System/Library/CoreServices/aaad
        2 0 40:00 /usr/libexec/bbbd
        3 0 30:00 /usr/sbin/cccd
        """
        let procs = ProcessAttribution.parse(psOutput: lines)
        // All system, none suppressed, all >= 600s. Highest = bbbd (40min).
        let off = ProcessAttribution.topSystemOffender(procs, minCPUSeconds: 600)
        #expect(off?.command == "bbbd")
    }

    @Test func topSystemOffender_emptyInput() {
        #expect(ProcessAttribution.topSystemOffender([], minCPUSeconds: 600) == nil)
    }

    // MARK: - Tolerant smoke for the single impure fn

    @Test func snapshotViaPS_isNilOrNonEmptyArray() {
        // On a clean runner /bin/ps exists and lists processes → non-empty.
        // If for any reason it can't launch/parse, the contract is `nil`
        // (graceful abstain). Either is acceptable; a present-but-EMPTY array
        // would indicate a parse regression.
        let result = ProcessAttribution.snapshotViaPS()
        if let result {
            #expect(!result.isEmpty, "ps ran but parsed zero rows → parse regression")
        }
        // nil is fine (CI sandbox could block exec); just must not crash.
    }
}

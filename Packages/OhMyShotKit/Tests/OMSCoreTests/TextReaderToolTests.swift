import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing
@testable import OMSCore

/// The one-picture run of the text reader, against stand-in readers written as shell scripts. Each test keeps its
/// own `ActiveResources`, so suites watching the shared one (HistoryTextTests) never see these runs.
struct TextReaderToolTests {
    private func helper(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSTextReaderToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "reader")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        return script
    }

    /// Reads the job, then answers for its id.
    private let answering = """
    read line
    id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
    join=$(printf '%s' "$line" | sed -E 's/.*"joinsWrappedLines":(true|false).*/\\1/')
    """

    @Test func theReaderIsAskedHowToAssembleAndItsTextComesBack() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"text\":\"join=%s\"}\\n' \"$id\" \"$join\"")
        let resources = ActiveResources()
        let joined = try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources)
        #expect(joined == "join=true")
        let kept = try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: false, helper: reader, resources: resources)
        #expect(kept == "join=false")
        #expect(resources.isIdle)
    }

    @Test func aReaderThatCouldNotReadSaysWhy() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"error\":\"unreadableImage\"}\\n' \"$id\"")
        await #expect(throws: TextReaderTool.Failure.unreadable("unreadableImage")) {
            try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: ActiveResources())
        }
    }

    @Test func aReaderThatEndsWithoutAnsweringIsNoAnswer() async throws {
        let reader = try helper("read line\nexit 3")
        let resources = ActiveResources()
        await #expect(throws: TextReaderTool.Failure.noAnswer(status: 3)) {
            try await TextReaderTool.text(ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources)
        }
        #expect(resources.isIdle)
    }

    @Test func thePacksOwnLinesComeBackWithTheirBoxes() async throws {
        // The job asks for the pack's lines alone, from its folder.
        let reader = try helper(answering + """

        case "$line" in *'"lines":true'*) ;; *) exit 4 ;; esac
        case "$line" in *packs*l2*) ;; *) exit 5 ;; esac
        printf '{"id":"%s","lines":[{"text":"打开设置","box":[[10,20],[120,30]],"confidence":0.98}]}\\n' "$id"
        """)
        let resources = ActiveResources()
        let lines = try await TextReaderTool.lines(ofPictureAt: URL(filePath: "/tmp/p.tiff"), pack: URL(filePath: "/packs/l2"), helper: reader, resources: resources)
        #expect(lines == [.init(text: "打开设置", box: CGRect(x: 10, y: 20, width: 120, height: 30), confidence: 0.98)])
        #expect(resources.isIdle)
    }

    @Test func warmingAPackReadsNoPicture() async throws {
        let reader = try helper(answering + """

        case "$line" in *'"path"'*) exit 4 ;; *'"warm":true'*) ;; *) exit 5 ;; esac
        printf '{"id":"%s","text":""}\\n' "$id"
        """)
        try await TextReaderTool.warm(pack: URL(filePath: "/packs/l2"), helper: reader, resources: ActiveResources())
    }

    @Test func aFormulaComesBackWithHowItsReadingEnded() async throws {
        // The job names the formula pack, not a PP-OCR one; the LaTeX comes back without spaces at its ends.
        let reader = try helper(answering + """

        case "$line" in *'"formula":"/packs/formula"'*) ;; *) exit 4 ;; esac
        case "$line" in *'"pack"'*) exit 5 ;; esac
        printf '{"id":"%s","latex":" x^{2}+y^{2} ","ending":"end"}\\n' "$id"
        """)
        let resources = ActiveResources()
        let formula = try await TextReaderTool.formula(ofPictureAt: URL(filePath: "/tmp/f.tiff"), pack: URL(filePath: "/packs/formula"), helper: reader, resources: resources)
        #expect(formula == .init(latex: "x^{2}+y^{2}", ending: "end"))
        #expect(formula.isFormula)
        #expect(resources.isIdle)
    }

    @Test func aStoppedReadingIsNoFormula() async throws {
        let reader = try helper(answering + "\nprintf '{\"id\":\"%s\",\"latex\":\"0000000000\",\"ending\":\"repeats\"}\\n' \"$id\"")
        let formula = try await TextReaderTool.formula(ofPictureAt: URL(filePath: "/tmp/f.tiff"), pack: URL(filePath: "/packs/formula"), helper: reader, resources: ActiveResources())
        #expect(formula.ending == "repeats" && !formula.isFormula)
        #expect(!TextReaderTool.Formula(latex: " ", ending: "end").isFormula)
    }

    @Test func warmingTheFormulaPackReadsNoPicture() async throws {
        let reader = try helper(answering + """

        case "$line" in *'"path"'*) exit 4 ;; *'"warm":true'*) ;; *) exit 5 ;; esac
        case "$line" in *'"formula":"/packs/formula"'*) ;; *) exit 6 ;; esac
        printf '{"id":"%s","text":""}\\n' "$id"
        """)
        try await TextReaderTool.warm(formula: URL(filePath: "/packs/formula"), helper: reader, resources: ActiveResources())
    }

    private final class FoundCounts: Sendable {
        let all = Mutex<[TextReaderTool.Found]>([])
    }

    @Test func tablesLeftForWantOfMemoryAreCounted() async throws {
        // The pressure the app stands in for the system's goes to the reader, which says how many tables it left.
        let reader = try helper(answering + """

        case "$line" in *'"vlm":"/packs/vlm"'*) ;; *) exit 6 ;; esac
        case "$line" in *'"pressure":"warning"'*) ;; *) exit 7 ;; esac
        printf '{"id":"%s","found":1,"foundTables":0}\\n' "$id"
        printf '{"id":"%s","formulas":[{"kind":"inline","box":[[1,2],[3,4]],"latex":"x"}],"tables":[],"tablesLeft":2}\\n' "$id"
        """)
        let found = FoundCounts()
        let read = try await TextReaderTool.elements(
            ofPictureAt: URL(filePath: "/tmp/p.png"), formulas: URL(filePath: "/packs/formula"), vlm: URL(filePath: "/packs/vlm"),
            pressure: .warning, helper: reader, found: { counts in found.all.withLock { $0.append(counts) } }, resources: ActiveResources()
        )
        #expect(read.formulas.map(\.latex) == ["x"] && read.tables.isEmpty && read.tablesLeft == 2)
        #expect(found.all.withLock { $0 } == [TextReaderTool.Found(formulas: 1, tables: 0)])
        #expect(MemoryPressure(name: "critical") == .critical && MemoryPressure(name: "high") == nil)
        #expect(MemoryPressure.warning > .normal && MemoryPressure.current() >= .normal)
    }

    @Test func tidyingReadsNothingAndSaysHowMuchWent() async throws {
        let reader = try helper(answering + """

        case "$line" in *'"path"'*|*'"pack"'*|*'"formula"'*) exit 4 ;; *'"tidy":true'*) ;; *) exit 5 ;; esac
        printf '{"id":"%s","removed":2}\\n' "$id"
        """)
        let resources = ActiveResources()
        #expect(try await TextReaderTool.tidy(helper: reader, resources: resources) == 2)
        #expect(resources.isIdle)
    }

    @Test func noReaderIsUnavailable() async throws {
        await #expect(throws: TextReaderTool.Failure.self) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: URL(filePath: "/nonexistent/reader"), resources: ActiveResources()
            )
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func aDeadlineStopsNativeWorkThatIgnoresTermination() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """)
        let resources = ActiveResources()
        // Process startup on a busy Mac can itself take a few hundred milliseconds. Leave enough
        // time to exercise the scripted hang, rather than timing out before the script reaches it.
        let started = ContinuousClock.now
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources,
                timeout: .seconds(2)
            )
        }
        #expect(ContinuousClock.now - started < .seconds(4))
        let pid = try #require(Int32(String(contentsOfFile: reader.path + ".pid", encoding: .utf8)))
        try await eventually { resources.isIdle && kill(pid, 0) != 0 }
    }

    @Test func cancellingAHungReaderReturnsAndKillsIt() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """)
        let resources = ActiveResources()
        let reading = Task {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources
            )
        }
        defer { reading.cancel() }
        try await eventually { FileManager.default.fileExists(atPath: reader.path + ".pid") }
        let pid = try #require(Int32(String(contentsOfFile: reader.path + ".pid", encoding: .utf8)))
        let started = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        try await eventually { resources.isIdle && kill(pid, 0) != 0 }
    }

    @Test func closingOutputWithoutExitingStillHasADeadline() async throws {
        let reader = try helper("""
        trap '' TERM
        read line
        exec 1>&-
        while :; do :; done
        """)
        let resources = ActiveResources()
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.lines(
                ofPictureAt: URL(filePath: "/tmp/p.png"), pack: URL(filePath: "/packs/l2"), helper: reader,
                resources: resources, timeout: .seconds(2)
            )
        }
        try await eventually { resources.isIdle }
    }

    @Test func progressDoesNotResetTheWholeRunDeadline() async throws {
        let reader = try helper(answering + """

        trap '' TERM
        printf '{"id":"%s","found":2,"foundTables":1}\\n' "$id"
        while :; do :; done
        """)
        let resources = ActiveResources()
        let found = FoundCounts()
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.elements(
                ofPictureAt: URL(filePath: "/tmp/p.png"), formulas: URL(filePath: "/packs/formula"), helper: reader,
                found: { value in found.all.withLock { $0.append(value) } }, resources: resources, timeout: .seconds(2)
            )
        }
        #expect(found.all.withLock { $0 } == [.init(formulas: 1, tables: 1)])
        try await eventually { resources.isIdle }
    }

    @Test func anExitedReadersDescendantCannotKeepTheCallerWaitingOnOutput() async throws {
        let reader = try helper("""
        read line
        /bin/sleep 10 &
        printf '%s' "$!" > "$0.child"
        exit 0
        """)
        defer {
            if let text = try? String(contentsOfFile: reader.path + ".child", encoding: .utf8), let pid = Int32(text) {
                _ = kill(pid, SIGKILL)
            }
        }
        let resources = ActiveResources()
        // Process startup on a busy Mac can itself take a few hundred milliseconds. Leave enough
        // time to exercise the scripted hang, rather than timing out before the script reaches it.
        let started = ContinuousClock.now
        await #expect(throws: TextReaderTool.Failure.timedOut) {
            try await TextReaderTool.text(
                ofPictureAt: URL(filePath: "/tmp/p.png"), joinsWrappedLines: true, helper: reader, resources: resources,
                timeout: .seconds(2)
            )
        }
        #expect(ContinuousClock.now - started < .seconds(4))
        try await eventually { resources.isIdle }
    }

    @Test func cancellingContinuousProgressStopsCallbacksAndCleansUp() async throws {
        let reader = try helper(answering + """

        trap '' TERM
        while :; do
            printf '{"id":"%s","found":1,"foundTables":0}\\n' "$id"
        done
        """)
        let resources = ActiveResources()
        let updates = Mutex(0)
        let reading = Task {
            try await TextReaderTool.elements(
                ofPictureAt: URL(filePath: "/tmp/p.png"), formulas: URL(filePath: "/packs/formula"), helper: reader,
                found: { _ in updates.withLock { $0 += 1 } }, resources: resources
            )
        }
        defer { reading.cancel() }
        try await eventually { updates.withLock { $0 > 0 } }
        let started = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        let stoppedAt = updates.withLock { $0 }
        try await eventually { resources.isIdle }
        try await Task.sleep(for: .milliseconds(100))
        #expect(updates.withLock { $0 } == stoppedAt)
    }
}

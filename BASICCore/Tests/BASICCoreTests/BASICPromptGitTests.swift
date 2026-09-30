//
//  BASICPromptGitTests.swift
//  BASICCoreTests
//
//  The prompt's git segments: what git status says, and taking the
//  segments out where there is nothing to show.
//

import Testing
@testable import BASICCore

@Suite
struct BASICPromptGitTests {
    typealias Git = BASICSession.PromptGitState

    @Test
    func porcelainGivesBranchAheadBehindAndChanges() {
        let status = """
        # branch.oid 0123456789abcdef
        # branch.head feature/ActiveUI
        # branch.upstream origin/feature/ActiveUI
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 abc abc Sources/A.swift
        ? Notes.txt
        """
        let git = BASICSession.promptGitState(fromPorcelain: status)
        #expect(git == Git(branch: "feature/ActiveUI ⇡2 ⇣1", changes: "!2"))
    }

    @Test
    func cleanTreeHasNoChanges() {
        let git = BASICSession.promptGitState(fromPorcelain: "# branch.oid abc\n# branch.head develop\n# branch.ab +0 -0\n")
        #expect(git == Git(branch: "develop", changes: ""))
    }

    @Test
    func detachedHeadShowsNothing() {
        let git = BASICSession.promptGitState(fromPorcelain: "# branch.oid abc\n# branch.head (detached)\n1 .M x\n")
        #expect(git == Git())
    }

    @Test
    func defaultTemplateWithoutGitJoinsDirectoryToReady() {
        let template = BASICSession.defaultPromptTemplate
        let result = BASICSession.droppingEmptyGitSegments(from: template, git: Git())
        let runs = BASICSession.promptRuns(result)

        #expect(!result.contains("gitstatus"))
        #expect(!result.contains("gitchanges"))
        #expect(!runs.contains { $0.text.contains("git") })
        let directory = runs.firstIndex { $0.text.contains("${currentdir}") }!
        // The arrow after the directory runs from its purple into Ready's green.
        #expect(BASICSession.isPowerlineArrow(runs[directory + 1].text))
        #expect(runs[directory + 1].escape == "\u{1B}[38;5;99;48;5;40m")
        #expect(runs[directory + 2].text == " Ready ")
    }

    @Test
    func cleanTreeDropsOnlyTheChangesSegment() {
        let template = BASICSession.defaultPromptTemplate
        let result = BASICSession.droppingEmptyGitSegments(from: template, git: Git(branch: "develop"))
        let runs = BASICSession.promptRuns(result)

        #expect(result.contains("${gitstatus}"))
        #expect(!result.contains("${gitchanges}"))
        let branch = runs.firstIndex { $0.text.contains("${gitstatus}") }!
        #expect(runs[branch + 1].escape == "\u{1B}[38;5;142;48;5;40m")
        #expect(runs[branch + 2].text == " Ready ")
    }

    @Test
    func fullGitKeepsTheTemplate() {
        let template = BASICSession.defaultPromptTemplate
        let result = BASICSession.droppingEmptyGitSegments(from: template, git: Git(branch: "develop", changes: "!3"))
        #expect(result == template)
    }

    @Test
    func lastGitSegmentHandsTheEndArrowToTheSegmentBefore() {
        let arrow = "\u{E0B0}"
        let template = "\u{1B}[38;5;15;48;5;99m ${currentdir} \u{1B}[38;5;99;48;5;142m\(arrow)\u{1B}[38;5;16;48;5;142m ${gitstatus} \u{1B}[38;5;142;49m\(arrow)\u{1B}[0m "
        let result = BASICSession.droppingEmptyGitSegments(from: template, git: Git())
        #expect(result == "\u{1B}[38;5;15;48;5;99m ${currentdir} \u{1B}[38;5;99;49m\(arrow)\u{1B}[0m ")
    }

    @Test
    func plainTextTemplatesKeepTheirOtherText() {
        let template = BASICSession.plainPromptTemplate
        #expect(BASICSession.droppingEmptyGitSegments(from: template, git: Git()) == template)
    }

    @Test
    func legacyDefaultMigrates() {
        #expect(BASICSession.migratedPromptTemplate(BASICSession.legacyDefaultPromptTemplate) == BASICSession.defaultPromptTemplate)
        #expect(BASICSession.migratedPromptTemplate("READY%nl> ") == "READY%nl> ")
    }
}

import Foundation

/// What the platform BASIC is running on can do, and the one way to say
/// what it cannot.
///
/// iPad and iPhone start no child processes, so everything that runs
/// another program (SYSTEM, SYSTEM$, EXEC, PIPE, WHICH, a shell command at
/// the prompt, and JIT, which runs the compiler) is missing there. Each says
/// so in the same words, naming itself, rather than failing somewhere deeper
/// or in its own phrasing. Some will come later: JIT has a plan for an
/// in-process compiler (Documents/INTERNAL_JIT.md).
public enum BASICPlatform {
    /// Whether this platform runs other programs. False on iPad and iPhone.
    public static var runsOtherPrograms: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    /// The message for `feature` on a platform that does not have it:
    /// "PIPE is not available on iPad/iPhone".
    public static func notAvailableMessage(_ feature: String) -> String {
        "\(feature) is not available on iPad/iPhone"
    }

    /// The error for `feature` on a platform that does not have it.
    public static func notAvailable(_ feature: String) -> BASICError {
        .runtime(notAvailableMessage(feature))
    }
}

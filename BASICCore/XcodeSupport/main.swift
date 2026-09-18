// The build half of the Xcode scheme (project.yml).
//
// A scheme has to build at least one target of its own, and a package's
// products cannot be scheme build targets, only dependencies. So this is
// that target: it links every library the package ships, which makes the
// scheme's Build compile all four the way Xcode will for any app that
// depends on them. It does nothing when run.
import BASICCore
import BASICLint
import BASICLintCodeWatch
import BASICSyntax

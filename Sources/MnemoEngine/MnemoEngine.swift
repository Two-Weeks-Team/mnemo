// Mnemo engine — umbrella.
//
// The app instantiates only `MnemoCoordinator`. Everything else is internal
// composition. See docs/mnemo-implementation-plan.md for the architecture and
// the critic-loop revisions (§10).

import Foundation

public enum MnemoEngine {
    /// Engine layer version. Bump on any change to a public type's shape.
    public static let version = "0.1.0-phase1"
}

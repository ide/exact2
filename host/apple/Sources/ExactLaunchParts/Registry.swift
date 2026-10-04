// The app's module launch parts (Exact Observe design §4.6). This file is the
// default, for an app with none; `build.mjs` generates the app's own beside
// copies of each `modules/<name>/apple/launch/*.swift` it names in `launch`.
import ExactKit

public enum ExactLaunchParts {
    public static let all: [ExactLaunchPart.Type] = []
}

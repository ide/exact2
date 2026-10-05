// The default, empty registry for an app with no module launch parts.
// `build.mjs` generates a replacement next to copies of each module's
// `apple/launch/*.swift` when app.json's `launch` names any.
import ExactKit

public enum ExactLaunchParts {
    public static let all: [ExactLaunchPart.Type] = []
}

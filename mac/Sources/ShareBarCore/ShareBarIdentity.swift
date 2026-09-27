/// The app's bundle identifier, shared so it lives in one place instead of a literal
/// repeated in every file that logs or names it. Also `Info.plist`'s `CFBundleIdentifier`
/// and the cask's `uninstall quit:` target; those stay in sync by hand until the pending
/// tool rename (DEC-007) touches all of them together.
public enum ShareBarIdentity {
    public static let bundleID = "foundation.d.share.bar"
}

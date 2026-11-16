import Foundation

/// The running app's version from its Info.plist (MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml),
/// sent in `Hello` so each side's log shows what it is talking to.
public enum AppVersion {
    public static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    public static var build: UInt32 { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { UInt32($0) } ?? 0 }
}

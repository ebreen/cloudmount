import Foundation

/// Detects macFUSE installation on the system
enum MacFUSEDetector {
    /// Standard installation paths for macFUSE
    private static let installPaths = [
        "/Library/Filesystems/macfuse.fs",
        "/System/Library/Filesystems/macfuse.fs"
    ]
    
    /// Check if macFUSE is installed
    static func isInstalled() -> Bool {
        installPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
    
    /// Get the installed version if available
    static func version() -> String? {
        for basePath in installPaths {
            let plistPath = "\(basePath)/Contents/Info.plist"
            guard FileManager.default.fileExists(atPath: plistPath),
                  let plist = NSDictionary(contentsOfFile: plistPath),
                  let version = plist["CFBundleShortVersionString"] as? String else {
                continue
            }
            return version
        }
        return nil
    }
}

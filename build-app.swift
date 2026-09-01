import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let buildExecutable = root.appendingPathComponent(".build/release/EchoNote")
let appURL = root.appendingPathComponent("dist/EchoNote.app")
let contentsURL = appURL.appendingPathComponent("Contents")
let macOSURL = contentsURL.appendingPathComponent("MacOS")
let resourcesURL = contentsURL.appendingPathComponent("Resources")
let infoPlistURL = root.appendingPathComponent("Sources/LectureAssistant/Resources/Info.plist")

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "EchoNoteBuild", code: Int(process.terminationStatus))
    }
}

try run("/usr/bin/swift", ["build", "-c", "release"])
try? fileManager.removeItem(at: appURL)
try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try fileManager.copyItem(at: buildExecutable, to: macOSURL.appendingPathComponent("EchoNote"))
try fileManager.copyItem(
    at: infoPlistURL,
    to: contentsURL.appendingPathComponent("Info.plist")
)
try fileManager.copyItem(
    at: root.appendingPathComponent("Sources/LectureAssistant/Resources/AppIcon.icns"),
    to: resourcesURL.appendingPathComponent("AppIcon.icns")
)
try run("/usr/bin/codesign", [
    "--force", "--deep", "--sign", "-",
    "--entitlements", root.appendingPathComponent("LectureAssistant.entitlements").path,
    appURL.path,
])
let infoData = try Data(contentsOf: infoPlistURL)
let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
let archiveURL = root.appendingPathComponent("dist/EchoNote-\(version)-macOS-arm64.zip")
try? fileManager.removeItem(at: archiveURL)
try run("/usr/bin/ditto", [
    "-c", "-k", "--sequesterRsrc", "--keepParent",
    appURL.path,
    archiveURL.path,
])
let dmgRootURL = root.appendingPathComponent("dist/dmg-root", isDirectory: true)
let dmgURL = root.appendingPathComponent("dist/EchoNote-\(version)-macOS-arm64.dmg")
try? fileManager.removeItem(at: dmgRootURL)
try? fileManager.removeItem(at: dmgURL)
try fileManager.createDirectory(at: dmgRootURL, withIntermediateDirectories: true)
try fileManager.copyItem(
    at: appURL,
    to: dmgRootURL.appendingPathComponent("EchoNote.app", isDirectory: true)
)
try fileManager.createSymbolicLink(
    at: dmgRootURL.appendingPathComponent("Applications", isDirectory: true),
    withDestinationURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
)
try run("/usr/bin/hdiutil", [
    "create",
    "-volname", "EchoNote \(version)",
    "-srcfolder", dmgRootURL.path,
    "-format", "UDZO",
    "-imagekey", "zlib-level=9",
    dmgURL.path,
])
try fileManager.removeItem(at: dmgRootURL)
print(appURL.path)
print(archiveURL.path)
print(dmgURL.path)

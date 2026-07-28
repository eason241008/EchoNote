import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let buildExecutable = root.appendingPathComponent(".build/release/EchoNote")
let appURL = root.appendingPathComponent("dist/EchoNote.app")
let contentsURL = appURL.appendingPathComponent("Contents")
let macOSURL = contentsURL.appendingPathComponent("MacOS")
let resourcesURL = contentsURL.appendingPathComponent("Resources")

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
    at: root.appendingPathComponent("Sources/LectureAssistant/Resources/Info.plist"),
    to: contentsURL.appendingPathComponent("Info.plist")
)
try run("/usr/bin/codesign", [
    "--force", "--deep", "--sign", "-",
    "--entitlements", root.appendingPathComponent("LectureAssistant.entitlements").path,
    appURL.path,
])
print(appURL.path)

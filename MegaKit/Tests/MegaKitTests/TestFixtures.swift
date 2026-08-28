import Foundation
import Testing

enum Live {
    static let enabled = ProcessInfo.processInfo.environment["MEGA_LIVE_TESTS"] != nil

    static let folderURL = "https://mega.nz/folder/7YdzBbYb#jH6VX0GcTngXCf6kBnQGDA"
    static let folderID = "7YdzBbYb"
    static let folderKey = "jH6VX0GcTngXCf6kBnQGDA"
    static let folderName = "Weezer - Weezer (2026)"
    static let rootHandle = "LIkEAD7L"
    static let nodeCount = 12

    static let smallFileHandle = "TR10SToa"
    static let smallFileName = "New Album Releases.url"
    static let smallFileSize = 111

    static let largeFileHandle = "SJkGyZxb"
    static let largeFileName = "06 - Hoops.mp3"
    static let largeFileSize = 6_610_126
}

let liveOnly: ConditionTrait = .enabled(if: Live.enabled, "set MEGA_LIVE_TESTS=1 to run tests that call MEGA")

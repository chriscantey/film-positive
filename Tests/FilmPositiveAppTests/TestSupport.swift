import XCTest
import FilmPositiveCore
@testable import FilmPositive

func repoSource(_ path: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(path), encoding: .utf8)
}

@MainActor
func scratchRollModel(frames count: Int, in scratch: URL, name: String = "roll") throws -> (AppModel, [Frame.ID]) {
    let roll = scratch.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    for i in 1...count {
        try Data(repeating: 0x42, count: 64)
            .write(to: roll.appendingPathComponent(String(format: "IMG_%04d.CR2", i)))
    }
    let model = AppModel(service: CPURenderService(profiles: try ProfileLibrary.bundled()))
    model.undoManager.groupsByEvent = false
    XCTAssertNotNil(model.addFolder(roll))
    let ids = (model.selectedFolder?.frames ?? []).map(\.id)
    XCTAssertEqual(ids.count, count)
    return (model, ids)
}

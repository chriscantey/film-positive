import XCTest
import SwiftUI
import AppKit
@testable import FilmPositive

/// Renders the three `CentreOriginTrack.LimitMark` forms side by side, to pick from.
///
/// Not an assertion, a picture, and skipped unless `FP_MARKER_OPTIONS_PNG` names where to
/// write it, so a normal test run never pays for it. The real track view draws every box.
/// Only the symbol, name and number on top are laid out here, with the row's own constants.
///
/// The span is the one the mark actually appears on: -2...2 after a typed 1.50, marks at -1
/// and 1. Rows at 0.50 (the fill stops short of the mark, which stands on the bare box) and
/// 1.50 (the fill runs past it). A held span at 0.50 is exactly what `RangeHold` keeps after
/// a 1.50 is dragged back inside.
@MainActor
final class LimitMarkSheetTests: XCTestCase {

    func testRenderTheLimitMarkOptions() throws {
        guard let out = ProcessInfo.processInfo.environment["FP_MARKER_OPTIONS_PNG"] else {
            throw XCTSkip("set FP_MARKER_OPTIONS_PNG to a path to render the sheet")
        }
        let r = ImageRenderer(content: Sheet())
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage, "the renderer produced no image")
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
    }

    private static let values = [0.5, 1.5]
    private static let boxWidth: CGFloat = 250

    private struct Sheet: View {
        var body: some View {
            VStack(spacing: 0) {
                Panel().environment(\.colorScheme, .dark)
                Panel().environment(\.colorScheme, .light)
            }
            // A test process renders the default blue accent, so the sheet sets a Pink accent
            // by value. Sampled from the value edge in a screenshot, because `systemPink`
            // renders rose red.
            .accentColor(Color(red: 247 / 255, green: 90 / 255, blue: 164 / 255))
        }
    }

    private struct Panel: View {
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            HStack(alignment: .top, spacing: 28) {
                ForEach(CentreOriginTrack.LimitMark.allCases, id: \.self) { mark in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title(mark)).font(.headline)
                        ForEach(LimitMarkSheetTests.values, id: \.self) { v in
                            Row(mark: mark, value: v)
                        }
                    }
                }
            }
            .padding(24)
            .background(scheme == .dark ? Color(white: 0.118) : Color(white: 0.925))
        }

        private func title(_ m: CentreOriginTrack.LimitMark) -> String {
            switch m {
            case .line: return "a. line (today)"
            case .dashed: return "b. full height dashed"
            case .notches: return "c. edge notches"
            }
        }
    }

    private struct Row: View {
        let mark: CentreOriginTrack.LimitMark
        let value: Double
        @FocusState private var focused: Bool

        var body: some View {
            HStack(spacing: 6) {
                CentreOriginTrack(value: .constant(value), range: -2...2, neutral: 0, isEnabled: true,
                                  onEditingChanged: { _ in }, onReleaseFocus: {},
                                  look: .capsule(ticks: [-1, 1]), limitMark: mark,
                                  isFocused: $focused,
                                  readoutClearance: EnhanceSliderRow.readoutText + EnhanceSliderRow.boxInset)
                    .overlay {
                        HStack(spacing: 8) {
                            Image(systemName: "circle.lefthalf.filled")
                                .foregroundStyle(.secondary)
                                .frame(width: EnhanceSliderRow.symbolColumn)
                            Text("Contrast")
                            Spacer(minLength: 4)
                            Text(value, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: EnhanceSliderRow.readoutColumn, alignment: .trailing)
                        }
                        .padding(.horizontal, EnhanceSliderRow.boxInset)
                    }
                    .frame(width: LimitMarkSheetTests.boxWidth)
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
    }
}

import Foundation
import FilmSidecar
import FilmPositiveCore

/// What one control shows for a whole selection.
///
/// The rule: a control that is meaningful on a group reads the group and
/// writes the group, and where the frames disagree it says Multiple rather than picking
/// one frame's value and looking authoritative. `Multiple` is not a value you can write.
/// It is the absence of a shared one, and every writer treats it as "nothing to show",
/// never as "nothing to write".
///
/// Generic and free of SwiftUI so the reading rules can be tested without a window, which
/// is the same shape `GridSelection` and `EnhanceControl` already use.
enum SharedValue<T: Equatable>: Equatable {
    /// Nothing is selected.
    case empty
    /// Every selected frame agrees.
    case uniform(T)
    /// The selected frames disagree.
    case multiple

    /// Reads a selection. One pass, stops at the first disagreement.
    init<S: Sequence>(_ values: S) where S.Element == T {
        var iterator = values.makeIterator()
        guard let first = iterator.next() else { self = .empty; return }
        while let next = iterator.next() {
            if next != first { self = .multiple; return }
        }
        self = .uniform(first)
    }

    /// The shared value, or nil when there is none. Nil from `empty` and nil from
    /// `multiple` are deliberately the same answer to "what should I display".
    var value: T? {
        if case .uniform(let v) = self { return v }
        return nil
    }

    var isMultiple: Bool {
        if case .multiple = self { return true }
        return false
    }

    var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

/// Everything the inspector needs to read off a selection, computed once per body rather
/// than once per control.
///
/// Two counts rather than one flag: a selection that mixes developed and undeveloped
/// frames is normal (a folder holds a whole roll and you just added it), and the develop
/// section has to be able to say so instead of hiding itself because one frame is raw.
struct SelectionSummary: Equatable {
    var count: Int
    var developedCount: Int

    var stock: SharedValue<String?>
    var tone: SharedValue<ToneMode?>
    var autoBalance: SharedValue<Bool?>
    /// The Base control: Auto, Picked or None per frame, from `BaseChoice`. A
    /// selection that disagrees shows no segment.
    var baseChoice: SharedValue<BaseChoice>
    /// The two manual color axes, asked SEPARATELY rather than as one `ColourAxes` pair.
    ///
    /// They are two rows and a person moves one of them, so a selection that agrees on the
    /// warm axis and disagrees on the green one has to say Multiple on the green row alone.
    /// A single `SharedValue<ColourAxes>` would report both rows Multiple over a
    /// disagreement in either, which hides a perfectly good shared value behind a word that
    /// means "you cannot see this".
    var warmAxis: SharedValue<Double?>
    var greenAxis: SharedValue<Double?>
    /// Some selected frame carries a non-zero axis, so the Base title reads lit. ANY frame
    /// rather than every frame, because the lit title is how a closed row says it holds an
    /// edit.
    var colourAxesInUse: Bool
    var look: SharedValue<String?>
    var enhance: [String: SharedValue<Double>]
    /// Each Levels handle read as a slider is, and each curve as its whole point list,
    /// so one channel can say Multiple while the others share a curve.
    var levels: [LevelsHandle: SharedValue<Double>]
    var curves: [CurveChannel: SharedValue<CurvePoints>]
    /// Some selected frame carries a Levels or a curve that is not identity, which is what
    /// shows each group's Reset.
    var levelsInUse: Bool
    var curvesInUse: Bool
    /// The Metadata rows. Read over EVERY selected frame, developed or not, because a
    /// capture block means the same thing on a negative as on a positive.
    var camera: SharedValue<String?>
    var film: SharedValue<String?>
    /// The day shot ("YYYY-MM-DD"), the film size as it reads (resolved per frame from the id
    /// and the capture app's name, so two frames agree on what they SHOW), and every recorded
    /// scan time (only the ones that exist, in selection order).
    var takenOn: SharedValue<String?>
    var filmSize: SharedValue<String?>
    var scannedAt: [Date]

    /// The Tone row's sliders. Each slider is asked SEPARATELY over the frames'
    /// effective values (their own, or their preset's while they hold none), for the reason
    /// the axes are: a selection that agrees on the black and differs on the exposure says
    /// Multiple on the exposure row alone.
    var toneSliders: [ToneSlider: SharedValue<Double>] = [:]
    /// Some selected frame carries its own tone values, so the Tone title reads lit. ANY
    /// frame, the axes' rule.
    var toneAdjustInUse = false
    /// The tone whose values the tracks grow from: the selection's shared tone, or Flat
    /// while the frames disagree about the tone itself, which is the tone the app defaults to.
    var toneOrigin: ToneMode = .flat
    /// The Stretch row, in percent, over effective develop: a frame with no value reads 100,
    /// the Full it renders at.
    var stretch: SharedValue<Double> = .empty
    /// Some selected frame carries its own Stretch, so the Tone title reads lit, the same
    /// any-frame rule as the four tone rows.
    var stretchInUse = false

    /// The tag a picker carries while the frames disagree. It is never written: every
    /// setter returns early on it, so Multiple can be SHOWN and cannot be CHOSEN.
    /// Namespaced so it can never collide with a real stock id or a real tag value.
    static let mixedTag = "fp.selection.multiple"

    var isEmpty: Bool { count == 0 }
    var undevelopedCount: Int { count - developedCount }
    /// The develop controls are meaningful when at least one frame carries a develop layer.
    var hasDevelop: Bool { developedCount > 0 }

    init(_ sidecars: [Sidecar]) {
        self.init(sidecars, effective: sidecars.map(\.develop))
    }

    /// The reading the inspector uses: develop values are read over EFFECTIVE
    /// develop, so an undeveloped frame's rows show the defaults it is being rendered
    /// through rather than nothing at all.
    ///
    /// `effective` is one entry per sidecar, in the same order, each the value
    /// `DevelopDefaults.develop(for:)` gave for that frame. Passing it in rather than
    /// computing it here keeps this type free of the model and the profile library, which is
    /// what lets the reading rules be tested without a window.
    ///
    /// `developedCount` still counts frames that carry a develop layer ON DISK. That is what
    /// `isDeveloped` has always meant and what Reset is still gated on; the change here is
    /// only about what the rows SHOW.
    init(_ sidecars: [Sidecar], effective: [DevelopSettings?]) {
        count = sidecars.count
        developedCount = sidecars.filter { $0.develop != nil }.count

        // Read over effective develop, skipping only the frames that have no answer at all
        // (no develop layer and no library loaded). A nil folded in as a value would report
        // Multiple for a selection whose frames agree, which hides a perfectly good shared
        // value behind a word that means "you cannot see this".
        let developed = effective.compactMap { $0 }
        stock = SharedValue(developed.map { Optional($0.stock) })
        tone = SharedValue(developed.map { Optional($0.tone) })
        autoBalance = SharedValue(developed.map { Optional($0.autoBalance) })
        baseChoice = SharedValue(developed.map { BaseChoice($0) })
        // Read over EFFECTIVE develop like every other develop field, so an undeveloped
        // frame's axis rows sit at the identity it is already being rendered through rather
        // than at nothing at all.
        warmAxis = SharedValue(developed.map { Optional($0.colourAxes.warm) })
        greenAxis = SharedValue(developed.map { Optional($0.colourAxes.green) })
        colourAxesInUse = developed.contains { !$0.colourAxes.isIdentity }

        look = SharedValue(sidecars.map(\.look))
        camera = SharedValue(sidecars.map { $0.capture?.camera })
        film = SharedValue(sidecars.map { $0.capture?.film })
        takenOn = SharedValue(sidecars.map { $0.capture?.takenOn })
        filmSize = SharedValue(sidecars.map {
            MetadataSection.filmSizeLabel(id: $0.capture?.filmSizeID, name: $0.capture?.filmSizeName)
        })
        scannedAt = sidecars.compactMap { $0.capture?.capturedAt }

        // Enhance reads over every selected frame: an undeveloped frame still has an
        // enhance layer, it is just the identity one.
        let settings = sidecars.map { $0.enhance ?? .identity }
        var table: [String: SharedValue<Double>] = [:]
        for control in EnhanceControl.all {
            table[control.id] = SharedValue(settings.map { control.value(in: $0) })
        }
        enhance = table
        levels = Dictionary(uniqueKeysWithValues: LevelsHandle.allCases.map { h in
            (h, SharedValue(settings.map { $0.levels[keyPath: h.path] }))
        })
        curves = Dictionary(uniqueKeysWithValues: CurveChannel.allCases.map { c in
            (c, SharedValue(settings.map { $0.curves[keyPath: c.path] }))
        })
        levelsInUse = settings.contains { !$0.levels.isIdentity }
        curvesInUse = settings.contains { !$0.curves.isIdentity }

        // The Tone row's Adjust, over effective develop like the rows above it.
        let tones = developed.map(ToneSlider.effective)
        for slider in ToneSlider.allCases {
            toneSliders[slider] = SharedValue(tones.map { slider.value(in: $0) })
        }
        toneAdjustInUse = developed.contains { $0.toneAdjust != nil }
        toneOrigin = tone.value.flatMap { $0 } ?? .flat
        stretch = SharedValue(developed.map(StretchControl.value))
        stretchInUse = developed.contains { $0.stretch != nil }
    }

    func value(for slider: ToneSlider) -> SharedValue<Double> {
        toneSliders[slider] ?? .empty
    }

    /// Where a tone row's track sits: the shared value, or the preset's own while the
    /// frames disagree. The fill grows from the scale's neutral, so a Multiple
    /// row draws its fill out to the preset's value, where an untouched row would sit.
    func trackPosition(_ slider: ToneSlider) -> Double {
        value(for: slider).value ?? originValue(slider)
    }

    /// The preset's value for a tone row: where a double-click returns it. The fill grows
    /// from the scale's neutral instead (`ToneSlider.neutral`).
    func originValue(_ slider: ToneSlider) -> Double {
        slider.value(in: ToneAdjust.preset(for: toneOrigin))
    }

    /// Where a tone row's preset tick is drawn: the shared tone's, and none while
    /// the frames disagree about the tone itself, since no one preset is theirs.
    func toneTick(_ slider: ToneSlider) -> Double? {
        tone.isMultiple ? nil : slider.tick(for: toneOrigin)
    }

    /// Where a Levels handle sits: the shared value, or its identity position while the frames
    /// disagree, as a slider parks at 0.
    func levelsPosition(_ h: LevelsHandle) -> Double {
        levels[h]?.value ?? h.identity
    }

    /// The shared Levels the track draws, each handle at its own reading.
    var shownLevels: Levels {
        var l = Levels.identity
        for h in LevelsHandle.allCases { l[keyPath: h.path] = levelsPosition(h) }
        return l
    }

    /// The curve the graph draws for a channel: the shared one, or identity while the frames
    /// disagree.
    func curve(_ c: CurveChannel) -> CurvePoints {
        curves[c]?.value ?? .identity
    }

    func value(for control: EnhanceControl) -> SharedValue<Double> {
        enhance[control.id] ?? .empty
    }

    /// The same question for a color axis, so the row asks the summary rather than
    /// branching on which axis it is at the call site.
    func value(for axis: ColourAxis) -> SharedValue<Double?> {
        switch axis {
        case .warm: return warmAxis
        case .green: return greenAxis
        }
    }

    /// Where a color axis track sits, which is zero while the frames disagree: the row is
    /// showing "no shared value", and the identity position is the only one that does not
    /// claim a frame is the representative one. The readout beside it says Multiple.
    func trackPosition(_ axis: ColourAxis) -> Double {
        value(for: axis).value.flatMap { $0 } ?? 0
    }

    /// What a slider sits at while the frames disagree. Zero rather than one frame's
    /// value: the slider is showing "no shared value", and parking it at the identity
    /// position is the only position that does not claim a frame is the representative
    /// one. The label beside it reads Multiple, so the position is never read as a number.
    func sliderPosition(_ control: EnhanceControl) -> Double {
        value(for: control).value ?? 0
    }
}

extension SelectionSummary {
    /// The subtitle under the window title. It carries only what the title cannot: the
    /// developed split. The title already names the count.
    var subtitle: String {
        guard count > 1, undevelopedCount > 0 else { return "" }
        if developedCount == 0 { return "none developed yet" }
        return "\(undevelopedCount) not yet developed"
    }

    /// The window title for the selection.
    func title(single: String?) -> String {
        switch count {
        case 0: return ""
        case 1: return single ?? ""
        default: return "\(count) Frames"
        }
    }
}

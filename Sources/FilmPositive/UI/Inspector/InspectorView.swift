import SwiftUI
import CoreGraphics
import FilmSidecar
import FilmPositiveCore

/// The inspector: develop, looks, the twenty enhance controls and the histogram.
///
/// It is the third column of the window's `NavigationSplitView`, so it is on screen
/// whenever the window is, and it fills in the moment a frame is selected. There is no
/// menu item that shows it and no sheet anywhere in this file.
///
/// Every write goes through `model.apply`, once, so undo, the debounced sidecar write and
/// the re-render all fall out of the one path. Nothing here renders, writes a sidecar or
/// touches another arm's state.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    @State private var histogram: FrameHistogram?
    @State private var coalescer: UndoCoalescer?
    @State private var lastLatencyMS: Double?
    /// Bumped when a Base click writes nothing, so the segmented control redraws.
    @State private var baseControlEpoch = 0

    /// The frame the PER-FRAME views follow: the histogram, the window title and the
    /// render the inspector asks for. It is the keyboard cursor when the cursor is inside
    /// the selection, so the picture the histogram describes is the one the arrows are on,
    /// and the first selected frame otherwise.
    ///
    /// Nothing that EDITS reads this. Every control reads `summary` and writes the whole
    /// selection. A control belongs to the gallery if it is meaningful on a group, and a
    /// histogram of forty frames is not one thing.
    private var leadFrame: Frame? {
        let frames = model.selectedFrames
        if let cursor = model.cursor, let hit = frames.first(where: { $0.id == cursor }) { return hit }
        return frames.first
    }

    /// What every control reads: one pass over the selection, computed once per body.
    private var summary: SelectionSummary { model.selectionSummary }

    var body: some View {
        return content
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        Group {
            if !summary.isEmpty {
                Form {
                    // What a paste just failed to carry, when it failed to carry anything.
                    // One line, no icon, no dismiss button: the paste did most of its job
                    // and an alert would overstate it. Goes away on the next selection.
                    if let note = model.pasteNote {
                        Section {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    developSection()
                    frameSection()
                    // Metadata sits under Frame: the names the capture recorded, readable
                    // and correctable. Metadata only, never a develop control.
                    MetadataSection(summary: summary)
                    // The histogram sits under Metadata and above Enhance, high in the form
                    // rather than at the bottom, so it is in view when it is open. Both
                    // fold from their titles and start open.
                    if let leadFrame { histogramSection(leadFrame) }
                    enhanceTitleSection()
                    enhanceSections()
                }
                .formStyle(.grouped)
                // Export at the bottom right, OUTSIDE the scrolling form, so it is in view
                // at any window height and however far the form is scrolled.
                .safeAreaInset(edge: .bottom, spacing: 0) { exportBar }
                .navigationTitle(summary.title(single: leadFrame?.name))
                .navigationSubtitle(summary.subtitle)
            } else {
                // One quiet line, no icon and no bold title. A third `ContentUnavailableView`
                // in a third column would make an empty window read as three announcements at
                // three heights. This column has nothing to announce, it only has to say what
                // would fill it.
                Text("Select a frame to see its settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if coalescer == nil { coalescer = UndoCoalescer(model.undoManager) } }
        // A drag interrupted by the view going away must not leave an undo group open,
        // which would disable undo for every other arm.
        .onDisappear { coalescer?.end() }
        // Starting the render belongs outside body evaluation: `proxy(for:)` mutates the
        // coordinator's in-flight table, and SwiftUI forbids touching observable state
        // while a body is being computed.
        .task(id: desiredRequest) {
            if let leadFrame { _ = model.renders.proxy(for: leadFrame) }
            absorbFreshPixels()
        }
        .onChange(of: freshRequest) { _, _ in absorbFreshPixels() }
        .onChange(of: isOpen(.histogram)) { _, _ in absorbFreshPixels() }
    }

    // MARK: export

    /// The panel's last step, beside the toolbar's export icon, so the panel reads as
    /// something you work in top to bottom and then export. It sits below Enhance, the last
    /// section, whichever sections are open.
    ///
    /// The toolbar's own Export, through the one `ExportButton`, so the action, the enabled
    /// rule and the hover help are the toolbar's. A standard bordered button at the Develop
    /// button's size and never the accent fill: Develop is the panel's one prominent button.
    /// The bar has the toolbar material under it, so the form scrolls under it cleanly.
    private var exportBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                ExportButton(place: .inspector)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityIdentifier("inspector.export")
            }
            .padding(.horizontal, Self.exportBarInset)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    /// From the panel's right edge to the Export button's.
    static let exportBarInset: CGFloat = 20

    // MARK: develop

    @ViewBuilder
    private func developSection() -> some View {
        Section {
            // The SAME rows for every selection, developed or not, on a group or a single,
            // with no sheet and no change of mode. An undeveloped frame's rows read the
            // defaults it is already being rendered through, and touching any of them writes
            // that layer down through the funnel in `AppModel.apply`.
            //
            // Folded from the Develop title, the body goes and the header with its Reset
            // stays.
            if isOpen(.develop) { Group {
                // The row set, from `PositiveRows.visibleRows`. Stock is always on screen.
                //
                // A plain `if` inside the Section rather than a DisclosureGroup, so the
                // rows draw as siblings and the section keeps its card (there is no
                // twisty, and nothing about this is a container the user opens).
                //
                // The draw order here is the declaration order of `PositiveRows.Row`, and
                // `PositiveRowsTests` asserts the order off the pure function. Both row
                // sets are subsequences of that one sequence, so an ordered pass with
                // `contains` cannot disagree with the function about order, only about
                // membership.
                let rows = visibleRows

                // Stock is the FIRST row and it is always drawn. Auto color sits under it
                // because what it governs is where the base comes from, not which film this
                // is.
                //
                // Black & White is an entry in this picker, as it is in the sidecar (the id
                // `bw-generic`).
                if rows.contains(.stock) {
                    // The row takes the Base row's shape. Title on the left with the free
                    // width, then the picker with its own label hidden.
                    HStack(spacing: 8) {
                        // The label group in `RowLabel`'s shape (title, 4 pt, info icon), as
                        // the Tone row carries its own. Stock is a choice of film and nothing
                        // else, so its title is a plain label: it opens no sliders, and the
                        // info icon beside it is the row's one button.
                        //
                        // The label group is fixed and never compresses (the label wrapped
                        // to "St/oc/k" when it could), because a long stock name ("Black &
                        // White Negative", 190 pt) cannot fit beside it at the 360 pt
                        // inspector. The picker is sized FIRST with whatever is left: its
                        // natural width when that fits, otherwise the remaining width with
                        // its title truncated.
                        HStack(spacing: 4) {
                            Label(StockChoices.rowTitle, systemImage: StockChoices.rowSymbol)
                                .accessibilityIdentifier("positive.stockTitle")
                            InfoGlyph(text: StockChoices.infoHover, identifier: "positive.stockInfo",
                                      popover: StockChoices.infoPopover)
                        }
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ViewThatFits(in: .horizontal) {
                            stockPicker.fixedSize()
                            stockPicker
                        }
                        .layoutPriority(1)
                    }
                }

                // The eyedropper sits OUTSIDE the Base control, as its row-mate: inside it, it
                // would inherit the control's disabled state on the generic stock, and a pick is
                // exactly what the user wants there.
                //
                // The row reads like Stock and Tone. On the left the icon, the word Base and
                // the row's info icon, in `RowLabel`'s shape (title, 4 pt, info icon). On the
                // right the segmented control, small as Tone's is, its trailing edge on the
                // column Stock's and Tone's controls end on. The eyedropper sits between the
                // two.
                //
                // The left group takes the free width with a flexible frame, not a
                // Spacer: a Spacer costs the HStack a second gap, and at the 360 pt
                // inspector that squeezes the word to 31 pt and wraps it. And the row is
                // not a `LabeledContent`, which is what the color axis rows use: a grouped
                // Form drops a LabeledContent's content to a second line under its label
                // unless it has far more room than it needs. Measured by Accessibility
                // frames at the 360 pt inspector (every window width up to 1350 keeps it
                // there): with the label ending at x 1271 and the controls needing only
                // 1291 to 1515, the Form still wraps them. A plain row has no such rule.
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        DevelopRowTitle(row: .base, open: DevelopRow.base.isOpen(model.prefs),
                                        lit: DevelopRow.base.lit(summary)) { model.toggleDevelopRow(.base) }
                            .disabled(monoSelection)
                        // The color axes fold into this row, and the title above is what
                        // shows or hides them. A preference only, never a sidecar, lit
                        // whenever a selected frame uses them. Disabled on black and white
                        // with its row-mates: the rows stay folded there.
                        //
                        // Where the color came from, as ONE icon and no text on the panel.
                        // Outside the picker so it stays live on a black and white selection,
                        // where the picker is disabled and the icon is what says why.
                        BaseInfoButton(source: BaseInfo.selection(baseInfoSources), text: BaseInfo.status(baseInfoSources))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Disabled from the ROW rather than inside the button. A pick writes a
                    // color base, and there is no color base on a black and white frame.
                    PickBaseButton()
                        .disabled(monoSelection)
                    // A three-way Base control, a view of `autoBalance` and `base.mode`, read
                    // and written through `BaseChoice`. Its own label stays hidden, because
                    // the row's Label says Base.
                    Picker(PositiveNames.base, selection: baseChoiceBinding) {
                        ForEach(BaseChoice.allCases) { choice in
                            Text(choice.title).tag(Optional(choice))
                        }
                    }
                    .pickerStyle(.segmented)
                    // Small, as Tone's segmented control is. At the regular size the
                    // row is wider than the 360 pt inspector minimum.
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(monoSelection)
                    .help(baseHelp)
                    // A click that writes nothing (Picked with no pair starts Pick Base)
                    // leaves the segmented control on the clicked segment, because its
                    // binding never changed. A new identity redraws it from the binding.
                    .id(baseControlEpoch)
                    .accessibilityIdentifier("positive.base")
                }
                // No note under the Base control for the forced case. A disabled control
                // still needs its reason, and the reason is the control's own help
                // (`baseHelp`) rather than a second line that pushes everything below it down.

                // The two manual color axes sit HERE, after the rows that decide where the
                // base came from and before Tone, and that is also the render order.
                //
                // The reasoning, so nobody has to re-derive it: the axes are a DELTA ON THE
                // RESOLVED BASE. Stock and Auto color between them settle which base this
                // frame gets, the axes move it from there, and Tone is what happens to the
                // result afterwards. Reading the section top to bottom is reading the
                // pipeline in order.
                //
                // They are drawn whether Auto color is on or off, because a base is
                // resolved by some route in every state of that toggle and the axes move it
                // whichever route it took. `PositiveRows.visibleRows` owns that
                // rule, and hides both rows on a mono selection where they are provably
                // inert. They fold behind the Base row's title too, and the remembered fold
                // alone decides whether they show (`PositiveRows.axesShown`): a closed row
                // with an edit shows its lit title and no sliders.
                //
                // One group under the Base title, indented, with no line and no caption.
                if rows.contains(.warmAxis) || rows.contains(.greenAxis) {
                    DevelopSliderGroup {
                        ForEach(ColourAxis.allCases) { axis in
                            if rows.contains(axis == .warm ? .warmAxis : .greenAxis) {
                                let shared = summary.value(for: axis)
                                ColourAxisRow(
                                    axis: axis,
                                    value: summary.trackPosition(axis),
                                    isMultiple: shared.isMultiple,
                                    onChange: { setColourAxis(axis, to: $0) },
                                    onEditing: { editing in
                                        // Every frame the edit reaches is under the drag, so all
                                        // of them want the cheap preview scale until it ends. In
                                        // the closeup that is the shown frame alone.
                                        model.renders.dragging = editing ? Set(model.selectedFrames.map(\.id)) : []
                                        if editing { coalescer?.begin(InspectorView.colourAxesAction) }
                                        else { coalescer?.end() }
                                    },
                                    onReset: { rowReset { setColourAxis(axis, to: 0) } },
                                    onReleaseFocus: { model.returnFocusToGrid() }
                                )
                                .disabled(monoSelection)
                            }
                        }
                    }
                }

                // A mixed selection shows the three segments with NONE of them selected,
                // which is the native convention, rather than growing a fourth "Multiple"
                // segment. A fourth segment takes the group to 240 pt and wraps the row at
                // the inspector's minimum width, and it claims Multiple is a tone you could
                // pick.
                //
                // The selection is Optional so SwiftUI has a legal value for "none of
                // these": handing a segmented picker a tag it is not rendering logs
                // `the selection ... is invalid and does not have an associated tag` and
                // draws whatever it likes. Every segment is therefore tagged
                // `Optional(rawValue)` and the binding reads nil while the frames disagree.
                //
                // The row takes the Base row's shape so the info icon can sit after the
                // word, label group on the left with the free width, the control on the
                // right with its own label hidden. A Picker's own label slot in a Form is not
                // a place a button can live.
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        // The title shows or hides the four tone rows below and never writes
                        // a sidecar, and it reads lit while a selected frame carries its own
                        // tone values. Live under every tone, color and mono.
                        DevelopRowTitle(row: .tone, open: DevelopRow.tone.isOpen(model.prefs),
                                        lit: DevelopRow.tone.lit(summary)) { model.toggleDevelopRow(.tone) }
                        ToneInfoButton(thin: ToneThin.status(stretchReadings))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Tone", selection: toneBinding) {
                        ForEach(ToneNames.all, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(Optional(mode.rawValue))
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    // The info icon explains the three tones, so the control itself only
                    // speaks while the frames disagree.
                    .help(summary.tone.isMultiple ? InspectorView.toneMixedHelp : "")
                    .accessibilityValue(summary.tone.isMultiple ? "Mixed" : "")
                }

                // The four tone rows, under the Tone row they adjust, in the axis rows'
                // style. Each shows the value the frame's tone runs. The fill grows from the
                // scale's neutral, so a picked preset moves the fill in the same frame its
                // readout changes, and a tick marks the preset's value.
                if ToneAdjustRows.shown(open: model.prefs.showsToneAdjust) {
                    // One group under the Tone title, indented, with no line and no caption:
                    // the four rows' own labels already say what each one does.
                    DevelopSliderGroup {
                        // Stretch first: it sets where white comes from, which the four tone
                        // rows then shape.
                        StretchRow(
                            value: summary.stretch.value ?? StretchControl.full,
                            isMultiple: summary.stretch.isMultiple,
                            onChange: { setStretch(to: $0) },
                            onEditing: { editing in
                                model.renders.dragging = editing ? Set(model.selectedFrames.map(\.id)) : []
                                if editing { coalescer?.begin(StretchControl.actionName) }
                                else { coalescer?.end() }
                            },
                            onReset: { rowReset { resetStretch() } },
                            onReleaseFocus: { model.returnFocusToGrid() }
                        )
                        ForEach(ToneSlider.allCases) { slider in
                            let shared = summary.value(for: slider)
                            ToneAdjustRow(
                                slider: slider,
                                value: summary.trackPosition(slider),
                                origin: summary.originValue(slider),
                                tick: summary.toneTick(slider),
                                isMultiple: shared.isMultiple,
                                onChange: { setToneSlider(slider, to: $0) },
                                onEditing: { editing in
                                    model.renders.dragging = editing ? Set(model.selectedFrames.map(\.id)) : []
                                    if editing { coalescer?.begin(ToneSlider.actionName) }
                                    else { coalescer?.end() }
                                },
                                onReset: { rowReset { resetToneSlider(slider) } },
                                onReleaseFocus: { model.returnFocusToGrid() }
                            )
                        }
                    }
                }

                // No line of tone numbers here. A line such as "black 0.11 -> 0.20,
                // white -> 0.92, exponent 0.77" is not adjustable, follows only the lead
                // frame, and therefore lies about a multi-selection. The numbers can be read
                // against a named frame in the render log. The same rule binds any later
                // stage, print contrast included: no rows of numbers under Tone.
                //
                // There is no note under the picker either: each segment does what it says.

                // The Positive button is the LAST ROW of this section, not a Section
                // of its own. Its own Section is what drew the separate card under the
                // group, which is the same mechanism `enhanceTitleSection` reads the other
                // way: a Section with a body gets a card.
                positiveButtonRow()
            } }
        } header: {
            positiveHeader()
        }
        // No footer. Every control applies to every selected frame, so there is no subset
        // to describe.
    }

    /// The Develop section header. A header and nothing else: the Positive button is the
    /// section's last row (`positiveButtonRow`), so this trailing slot carries Reset and
    /// only Reset.
    ///
    /// Named Develop. The button in its last row, the toolbar button and the context menu
    /// action are Positive: those make a positive, where this section holds how one is
    /// developed.
    ///
    /// `headerSlotHeight` keeps every section header the same height whether its slot holds
    /// a button or not.
    @ViewBuilder
    private func positiveHeader() -> some View {
        sectionHeader("Develop", resetTitle: "Reset",
                      enabled: summary.hasDevelop, fold: .develop) { model.resetDevelopSelection() }
            .padding(.bottom, foldedGap(.develop))
    }

    /// The Positive button, the last row of the Develop section.
    ///
    /// Trailing in the row, at the regular control size so the row is the height of its
    /// neighbours. It is ALWAYS drawn, so nothing below it moves when the last frame in the
    /// selection becomes a positive: it goes quiet in place instead.
    ///
    /// The quiet state is a BORDERLESS disabled button, never a disabled prominent one. A
    /// greyed capsule reads as broken, where a secondary checkmark and one word reads as
    /// done. Both states are a `Button` carrying the same accessibility identifier, so an
    /// Accessibility walk finds one element whatever the selection holds.
    ///
    /// Pressing it runs the same `developSelection` as Command D, the Develop menu item,
    /// the toolbar button and the context menu item, with no sheet in front of any of them.
    /// That call commits the values the rows are already showing, so what appears is the
    /// frame the inspector was describing.
    @ViewBuilder
    private func positiveButtonRow() -> some View {
        let unprocessed = summary.undevelopedCount
        HStack {
            Spacer()
            if unprocessed == 0 {
                Button {} label: {
                    Label(PositiveButton.title(unprocessed: 0), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .foregroundStyle(.secondary)
                .disabled(true)
                // The same height as the prominent button it replaces (24 pt at the regular
                // size), so the row and the card do not shrink by 8 pt when the last frame
                // turns positive.
                .frame(height: 24)
                .accessibilityIdentifier("positive.button")
                .help(PositiveButton.help(unprocessed: 0))
            } else {
                Button(PositiveButton.title(unprocessed: unprocessed)) { model.developSelection() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .controlSize(.regular)
                    .accessibilityIdentifier("positive.button")
                    .help(PositiveButton.help(unprocessed: unprocessed))
            }
        }
    }

    /// The rows the Develop section draws right now, from the pure rule.
    private var visibleRows: [PositiveRows.Row] {
        PositiveRows.visibleRows(autoColor: summary.autoBalance, mono: monoSelection,
                                 axesOpen: model.prefs.showsColourAxes)
    }

    /// What the info icon beside the word Base describes: each selected frame's base, lead
    /// frame first, reduced by `BaseInfo.selection` for the glyph and `BaseInfo.status` for
    /// the words. Reads the sidecars and the memoised analyses only, so drawing the
    /// inspector never starts a render.
    private var baseInfoSources: [BaseSource?] {
        let profiles = model.renders.profiles
        var frames = model.selectedFrames
        if let lead = leadFrame, let i = frames.firstIndex(where: { $0.id == lead.id }) {
            frames.insert(frames.remove(at: i), at: 0)
        }
        return frames.map { frame in
            BaseInfo.source(develop: frame.sidecar.develop, profiles: profiles,
                            rendered: model.renders.analysis(for: frame.id)?.baseSource)
        }
    }

    /// Whether the selection AGREES on a black and white stock.
    ///
    /// Agreement is the whole condition: a mixed selection holding one B&W frame keeps the
    /// toggle live, because turning the film edge search off there is still a real edit to the
    /// color frames in it. `summary.stock.value` is nil for a disagreeing selection, so
    /// the guard states that rather than testing for it separately.
    private var monoSelection: Bool {
        guard let profiles = model.renders.profiles,
              let stock = summary.stock.value.flatMap({ $0 }),
              stock != SelectionSummary.mixedTag
        else { return false }
        return profiles.resolveFilm(stock).profile.isMono
    }

    /// The toggle's tooltip. A black and white selection says why the switch is disabled.
    private var baseHelp: String {
        monoSelection ? PositiveNames.monoHelp : PositiveNames.baseHelp
    }

    /// The tag the Film Stock picker DISPLAYS, for this selection, right now.
    private var stockTag: String {
        InspectorView.stockPickerTag(for: summary.stock.value.flatMap { $0 },
                                     isMultiple: summary.stock.isMultiple)
    }

    /// The tag a picker is handed must name an item the picker is currently rendering, and
    /// `nil` is not a tag.
    ///
    /// Absent is not the same question as disagreeing: `SharedValue` returns nil from
    /// `.empty` as well as from `.multiple`. Answering `mixedTag` for ANY absent value would
    /// point a selection holding no shared stock, without disagreeing, at the one row that is
    /// rendered only while the frames DO disagree. The picker then matches nothing, draws
    /// blank and logs `Picker: the selection "fp.selection.multiple" is invalid and does not
    /// have an associated tag`.
    ///
    /// No stock recorded means the generic color negative, which is the sidecar literal
    /// `"generic"` and the row `StockChoices.list` always emits first. The invariant this
    /// function carries, and `StockRowTests` asserts: the tag it returns always names an
    /// item the picker is currently rendering.
    static func stockPickerTag(for id: String?, isMultiple: Bool) -> String {
        if isMultiple { return SelectionSummary.mixedTag }
        return id ?? StockChoices.genericID
    }

    /// The blocks the picker RENDERS, built around the tag rather than around the raw
    /// summary, so the two cannot disagree. Routing both through `stockPickerTag` is what
    /// makes "every producible tag names a rendered row" structural.
    private var stockGroups: [StockChoices.StockGroup] {
        let tag = stockTag
        if tag == SelectionSummary.mixedTag {
            let mixed = StockChoices.StockGroup(
                role: .mixed,
                choices: [StockChoice(id: SelectionSummary.mixedTag, name: "Multiple", kind: .unprofiled)])
            return [mixed] + StockChoices.groups(from: model.renders.profiles, current: nil)
        }
        return StockChoices.groups(from: model.renders.profiles, current: tag)
    }

    /// Reads the shared stock, or the Multiple placeholder. Writing the placeholder is not
    /// possible: it is the selected tag only while the frames disagree, and choosing any
    /// real stock writes it to every developed frame in the selection.
    private var stockBinding: Binding<String> {
        Binding(
            get: { stockTag },
            set: { newID in
                guard newID != SelectionSummary.mixedTag else { return }
                guard newID != (summary.stock.value.flatMap { $0 }) else { return }
                if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: "stock") }
                model.applyToSelection({ sidecar in
                    guard var develop = sidecar.develop else { return sidecar }
                    develop.stock = newID
                    return SidecarEdits.setDevelop(sidecar, develop)
                }, actionName: "Stock")
            }
        )
    }

    /// The Stock picker, its own label hidden because the row's Label says Stock.
    /// A property because the row draws it twice inside a `ViewThatFits`: at its natural
    /// width when that fits, otherwise compressed.
    private var stockPicker: some View {
        Picker("Stock", selection: stockBinding) {
            // Three blocks with a divider between them: the two answers that always work,
            // the shipped stocks by maker, then the person's own imported profiles when any
            // exist.
            ForEach(Array(stockGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group.choices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
        }
        // Explicit, because the dividers only draw in a pop-up menu and the
        // inferred style is what a Form happens to choose.
        .pickerStyle(.menu)
        .labelsHidden()
        .help(stockHelp)
    }

    /// The tone tag the segmented row DISPLAYS, or nil for "none of these".
    ///
    /// Pure and static so the one rule that matters has a test: a selection whose frames
    /// disagree selects NOTHING, and every other state selects the tone they share. The
    /// mixed tag never reaches a segmented picker again, because it is not a segment.
    static func tonePickerTag(for tone: ToneMode?, isMultiple: Bool) -> String? {
        if isMultiple { return nil }
        return tone?.rawValue
    }

    /// What the row says while the frames disagree. A picker showing nothing selected has
    /// to say why somewhere, and the tooltip is where, since the segments themselves are
    /// the three real answers.
    static let toneMixedHelp = "Frames use different tones. Pick one to set them all."

    private var toneBinding: Binding<String?> {
        Binding(
            get: { InspectorView.tonePickerTag(for: summary.tone.value.flatMap { $0 },
                                               isMultiple: summary.tone.isMultiple) },
            set: { tag in
                // A pick on a mixed selection still writes that tone to every frame, which
                // is why the guard is on the VALUE being real rather than on the selection
                // agreeing beforehand.
                guard let tag, let mode = ToneMode(rawValue: tag) else { return }
                // A pick of the tone the selection already has still runs while a frame
                // carries its own values: it is how a person goes back to the preset.
                guard mode != summary.tone.value.flatMap({ $0 }) || summary.toneAdjustInUse else { return }
                if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: "tone") }
                // The pick sets the tone at its own values, so the four tone rows jump to
                // the preset (`ToneSlider.pick`).
                model.applyToSelection({ ToneSlider.pick($0, mode) }, actionName: "Tone")
            }
        )
    }

    /// The Base control's selection. A black and white selection reads None, greyed,
    /// whatever is stored, and the stored value is untouched so it comes back when the stock
    /// goes back to color. A selection that disagrees reads nil, so no segment is lit.
    /// Setting nil is never a write.
    private var baseChoiceBinding: Binding<BaseChoice?> {
        Binding(
            get: { monoSelection ? BaseChoice.none : summary.baseChoice.value },
            set: { choice in
                guard let choice, !monoSelection else { return }
                guard choice != summary.baseChoice.value else { return }
                if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: "base") }
                if !model.chooseBase(choice) { baseControlEpoch += 1 }
            }
        )
    }

    // MARK: frame

    /// Quarter turns, mirror and Detect Crop, at the SELECTION level.
    ///
    /// These belong here and fine rotation does not, which is the gallery-versus-viewer rule
    /// doing its job: a quarter turn and a mirror mean the same thing on forty frames as on
    /// one (a roll loaded backwards is backwards all the way through), while a straighten
    /// angle and a crop box are measurements of one picture and cannot be shared.
    ///
    /// Detect Crop sits in this row rather than in the grid toolbar for that same reason: it
    /// is a selection-level geometry action, so it belongs beside the other selection-level
    /// geometry actions and not in a bar whose remaining job is leaving the app. The section
    /// is called Frame because it holds more than orientation.
    @ViewBuilder
    private func frameSection() -> some View {
        Section {
            if isOpen(.frame) { HStack(spacing: 8) {
                orientationButton("Rotate Left", "rotate.left") { turn(-90) }
                orientationButton("Rotate Right", "rotate.right") { turn(90) }
                orientationButton("Mirror", "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                  active: isMirrored) { mirror() }
                // Only frames that are already positive can be cropped, because the detector
                // reads the developed frame. Frames open as negatives, so this is disabled
                // until Positive has been pressed, which is intended.
                //
                // "Detect Crop", not "Auto Crop". Nothing in this app crops or rotates on its
                // own, and a name with Auto in it says otherwise.
                orientationButton("Detect Crop", "rectangle.dashed",
                                  enabled: model.selectedFrames.contains(where: \.isDeveloped),
                                  help: "Find the film edge in the selected frames") {
                    model.showsAutoCropSheet = true
                }
                Spacer()
                if let status = orientationStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } }
        } header: {
            // The same header shape Develop, Looks and Enhance carry. A
            // section whose header slot is empty while its neighbours all hold a Reset
            // reads as a section you cannot undo.
            sectionHeader("Frame", resetTitle: "Reset", enabled: model.hasFrameGeometry, fold: .frame) {
                model.resetFrameSelection()
            }
            .padding(.bottom, foldedGap(.frame))
        }
    }

    /// What the frame's orientation currently IS, which the three buttons do not say.
    ///
    /// Single selection only, and that is not a simplification. On a group these are two
    /// different answers at once, and one line saying "90 degrees, Mirrored" over a
    /// selection where half the frames are neither would be worse than saying nothing.
    private var orientationStatus: String? {
        guard summary.count == 1, let g = leadFrame?.sidecar.geometry else { return nil }
        var parts: [String] = []
        if g.rotate != 0 { parts.append("\(g.rotate)°") }
        if g.flip { parts.append("Mirrored") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Only meaningful for one frame, for the same reason. A tinted button over a mixed
    /// selection would claim every frame in it is mirrored.
    private var isMirrored: Bool {
        summary.count == 1 && leadFrame?.sidecar.geometry?.flip == true
    }

    /// `enabled` is an extra gate on top of the shared one, not a replacement: an empty
    /// selection disables every button in the row regardless. Detect Crop is the one caller
    /// that passes it, because the detector needs a developed frame to read.
    ///
    /// `help` defaults to the title, which is right for the three buttons whose name says
    /// the whole thing. Detect Crop passes a sentence, so the tooltip explains what gets
    /// detected while the accessibility label stays the short name.
    private func orientationButton(_ title: String, _ symbol: String, active: Bool = false,
                                   enabled: Bool = true, help: String? = nil,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(help ?? title)
            .accessibilityLabel(title)
            .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .disabled(summary.isEmpty || !enabled)
    }

    /// One path with the Image menu and the context menu.
    private func turn(_ degrees: Int) { model.rotateSelection(clockwise: degrees > 0) }

    private func mirror() {
        model.applyToSelection({ sidecar in
            var g = sidecar.geometry ?? GeometrySettings()
            g.flip.toggle()
            return SidecarEdits.setGeometry(sidecar, g)
        }, actionName: "Mirror")
    }

    // MARK: enhance

    /// The rows ride in each group's Section HEADER, and the body is empty.
    ///
    /// Every row is its own box on the window background with a 7 pt gap, and a grouped
    /// Form on macOS will not give that up for a body row: with `listRowBackground`,
    /// `listRowSeparator` and `listRowInsets` the card, the separators and a 55 pt row pitch
    /// all stay. A header gets no card, no separator and no row padding. An empty body also
    /// gets no section gap, so each group pays its own gap under its last row,
    /// `enhanceGroupGap`, the same for every group.
    ///
    /// Folded Enhance draws none of the groups. A folded group keeps its title line, the
    /// Color wand included, and drops its rows. The group gap stays under it.
    @ViewBuilder
    private func enhanceSections() -> some View {
        if isOpen(.enhance) { ForEach(EnhanceControl.Group.allCases) { group in
            let fold = InspectorSection.group(group)
            Section {
            } header: {
                VStack(alignment: .leading, spacing: Self.enhanceTitleToRows) {
                    // 6 pt, the Enhance header's spacing, so both wands sit the same distance
                    // after their titles.
                    HStack(spacing: 6) {
                        FoldTitle(fold.title, open: isOpen(fold), action: { model.toggleSection(fold) }) {
                            groupTitle(group)
                        }
                        // The cast neutralizer sits with the color controls it moves, the
                        // Color group's own Auto, drawn as the Enhance Auto's wand beside the
                        // word Color.
                        if group == .colour {
                            NeutraliseCastButton()
                        }
                        Spacer(minLength: 0)
                    }
                    if isOpen(fold) { VStack(spacing: Self.enhanceRowGap) {
                        ForEach(EnhanceControl.group(group)) { control in
                            enhanceRow(control)
                        }
                    }
                    // Out to the edges a card has, so the boxes line up with the Looks card
                    // above them. A header's content is inset from those edges by this much.
                    .padding(.horizontal, -Self.headerInset)
                    // A header's type is the Form's to choose, and it chooses a smaller grey
                    // one after an empty Section. Pinned so the rows read
                    // the same in every group whatever sits above them.
                    .font(.body)
                    .fontWeight(.regular)
                    .foregroundStyle(.primary)
                    .textCase(nil) }
                }
                .padding(.bottom, Self.enhanceGroupGap)
            }
            // Levels and Curves sit between Color and Detail on screen. Only the order on
            // screen: the render chain still runs them where it always has, and their
            // stored keys do not move.
            if group == .colour { toneSections() }
        } }
    }

    /// The Levels and Curves groups, each the header of a Section of its own
    /// (`ToneGroupSection`), with the same band and gap as the slider groups.
    @ViewBuilder
    private func toneSections() -> some View {
        ToneGroupSection(fold: .levels, open: isOpen(.levels), inUse: summary.levelsInUse,
                         toggle: { model.toggleSection(.levels) }, reset: { model.resetLevelsSelection() }) {
            LevelsGroup(summary: summary,
                        entering: EnteringHistogram.request(.levels, from: desiredRequest),
                        service: model.renders.service,
                        onSet: { handle, value in
                            if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: handle.id) }
                            model.setLevelsHandle(handle, to: value)
                        },
                        onEditing: toneEditing(AppModel.levelsAction))
        }
        ToneGroupSection(fold: .curves, open: isOpen(.curves), inUse: summary.curvesInUse,
                         toggle: { model.toggleSection(.curves) }, reset: { model.resetCurvesSelection() }) {
            CurvesGroup(summary: summary,
                        entering: EnteringHistogram.request(.curves, from: desiredRequest),
                        service: model.renders.service,
                        onSet: { channel, points in
                            if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: "curves.\(channel.id)") }
                            model.setCurve(channel, to: points)
                        },
                        onEditing: toneEditing(AppModel.curvesAction))
        }
    }

    /// A tone drag, as a slider drag: the cheap preview scale for every frame it reaches, and
    /// one undo step for the whole drag.
    private func toneEditing(_ actionName: String) -> (Bool) -> Void {
        { editing in
            model.renders.dragging = editing ? Set(model.selectedFrames.map(\.id)) : []
            if editing { coalescer?.begin(actionName) } else { coalescer?.end() }
        }
    }

    private func enhanceRow(_ control: EnhanceControl) -> some View {
        let shared = summary.value(for: control)
        return EnhanceSliderRow(
            control: control,
            value: shared.value ?? 0,
            isMultiple: shared.isMultiple,
            onChange: { setEnhance(control, to: $0) },
            onEditing: { editing in
                // Every frame the edit reaches is under the drag, not just the lead
                // frame, so all of them want the cheap preview scale until the drag
                // ends. In the closeup that is the shown frame alone.
                model.renders.dragging = editing ? Set(model.selectedFrames.map(\.id)) : []
                if editing { coalescer?.begin(control.label) } else { coalescer?.end() }
            },
            onReset: { rowReset { setEnhance(control, to: 0) } },
            onReleaseFocus: { model.returnFocusToGrid() },
            frameKey: enhanceHoldKey
        )
    }

    /// What a held range lets go on: the frame shown, or the selection changing.
    private var enhanceHoldKey: AnyHashable {
        AnyHashable([leadFrame?.id] + model.selectedFrames.map { Optional($0.id) })
    }

    /// From a group title to its first box.
    static let enhanceTitleToRows: CGFloat = 5
    /// How far a grouped Form insets a header's content from the card edges, measured on
    /// screen (title at 1285, the Looks card from 1277 to 1654).
    static let headerInset: CGFloat = 8
    /// Under a group's last box, standing in for the section gap an empty body does not get.
    static let enhanceGroupGap: CGFloat = 18

    /// The space between two enhance boxes.
    static let enhanceRowGap: CGFloat = 7

    /// The Enhance title and its Reset, with Looks as the first row under it.
    ///
    /// This Section holds the Looks row so that it is not empty while Enhance and Looks are
    /// open. Two empty Sections back to back make a grouped Form draw the second header
    /// ("Enhance") as small grey text instead of a heading.
    ///
    /// Each Enhance group is the header of a Section of its own, so every group gets the
    /// same band and gap. The Looks title rides in this header, under the Enhance line, in
    /// the same group-title style.
    ///
    /// Folding is the one way this Section goes empty: Looks folded, or Enhance folded. That
    /// does not cost the heading, because every title here is styled by its own code, and
    /// the missing card's gap is paid under the header by `foldedGap`, as the Histogram and
    /// Metadata headers pay it when closed.
    ///
    /// Enhance folded is the DEFAULT state (`SectionFold.defaultClosed`), and with Histogram
    /// and Metadata also closed there are three empty Sections back to back, each title still
    /// a heading at an even pitch.
    @ViewBuilder
    private func enhanceTitleSection() -> some View {
        Section {
            // A look is only a named set of enhance values, so it lives with them, and it
            // has no Reset of its own: the Enhance Reset above clears the same layer.
            if isOpen(.enhance) && isOpen(.looks) { LooksRow(applied: summary.look) }
        } header: {
            VStack(alignment: .leading, spacing: Self.looksTitleGap) {
                // Reset resets the whole enhance layer, not one group, which is why it
                // lives up here beside the name and is not repeated on any group, Looks
                // included. Same shape as Develop.
                // The Auto wand sits on the title line beside the word Enhance and never in
                // the Looks row, its hover help the one explanation it carries. Reset stays
                // at the right edge as on Develop.
                sectionHeader("Enhance", resetTitle: "Reset", enabled: true, fold: .enhance,
                              accessory: AnyView(AutoEnhanceButton())) {
                    model.resetEnhanceSelection()
                }
                if isOpen(.enhance) { looksTitle }
            }
            .padding(.bottom, isOpen(.enhance) ? foldedGap(.looks) : foldedGap(.enhance))
        }
    }

    /// From the Enhance line to the Looks title. With Looks as its own Section, the Enhance
    /// heading's bottom to the Looks title's top measures 29 pt, matching the 29 to 31 pt at
    /// the other group boundaries. The header slot adds 2 pt under the text, so 27 keeps
    /// that distance. Checked by reading the pixels back.
    private static let looksTitleGap: CGFloat = 27

    /// The Enhance group titles, in ONE style, so the inspector reads as one family.
    /// Subheadline semibold secondary sits between the section title above it and the
    /// slider labels below it, which is the rank a group title holds. Every group title goes
    /// through here: a bare `Text(group.rawValue)` in the header is what
    /// `EnhanceGroupHeaderTests` forbids.
    ///
    /// One style is not enough on its own: every group also has to be the header of a
    /// Section of its own, or the one that is not gets neither the section gap nor the
    /// header band. That is what `enhanceTitleSection` exists to make possible.
    @ViewBuilder
    private func groupTitle(_ group: EnhanceControl.Group) -> some View {
        Text(group.rawValue)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// The Looks title, in the group-title style so it reads as a peer of Light, Color and
    /// Detail. Kept apart from `groupTitle` because Looks is not an `EnhanceControl.Group`.
    /// It folds the Looks row, as a group title folds its rows.
    private var looksTitle: some View {
        FoldTitle(InspectorSection.looks.title, open: isOpen(.looks),
                  action: { model.toggleSection(.looks) }) {
            Text("Looks")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// A section title with its Reset on the same line, since Reset clears everything in
    /// the section.
    ///
    /// `accessory` sits right after the title, 6 pt on, and Reset alone at the right. The
    /// Enhance wand rides there, so it reads as belonging to the word beside it, as the
    /// Color group's does.
    ///
    /// The title folds `fold`, and the row stays, so Reset and the wand are in reach while
    /// the body is folded.
    @ViewBuilder
    private func sectionHeader(_ title: String, resetTitle: String, enabled: Bool,
                               fold: InspectorSection, accessory: AnyView? = nil,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            FoldTitle(title, open: isOpen(fold), action: { model.toggleSection(fold) }) {
                Self.sectionTitle(title)
            }
            if let accessory { accessory }
            Spacer()
            Button(resetTitle, action: action)
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!enabled)
        }
        .frame(height: InspectorView.headerSlotHeight)
    }

    /// Every inspector section title, styled HERE rather than by the Form. A grouped Form
    /// draws the header of the Section after an empty one as plain small grey text. Set
    /// explicitly, the font, color and heading trait cannot be taken away by whatever sits
    /// above, so every title looks the same in every state.
    static func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    /// The Positive pill is a 20 pt bordered button and the Reset link is 13 pt. Same slot
    /// means same height, or the rows below move 4 pt every time the slot swaps. Pinned to
    /// the taller of the two.
    static let headerSlotHeight: CGFloat = 20

    /// What the Stock picker is for, as a tooltip.
    private var stockHelp: String {
        summary.stock.value.flatMap({ $0 }) == nil ? InspectorView.stockMixedHelp : InspectorView.stockOneHelp
    }

    static let stockOneHelp = "The film the roll was shot on."
    static let stockMixedHelp = "Frames use different films. Pick one to set them all."

    /// The undo action name both axis rows share.
    ///
    /// ONE name for the pair, not one per row. Undo names what the user thinks they did, and
    /// "Color Axes" covers a nudge on either row without the Edit menu flickering between
    /// two entries as they work across both.
    static let colourAxesAction = "Colour Axes"

    /// Writes ONE axis over the whole selection, carrying each frame's own other axis
    /// through untouched.
    ///
    /// The rule itself is `ColourAxis.edit`, which is where it can be asserted without a
    /// window. This is only the selection wrapper and the latency stamp.
    private func setColourAxis(_ axis: ColourAxis, to value: Double) {
        if let lead = leadFrame {
            SliderLatency.shared.edited(frame: lead.id, control: "colourAxis.\(axis.id)")
        }
        model.applyToSelection({ axis.edit($0, to: value) },
                               actionName: InspectorView.colourAxesAction)
    }

    /// Writes ONE tone value over the whole selection, each frame keeping its own other
    /// three (`ToneSlider.edit`). The axes' selection wrapper, for the Tone row's Adjust.
    private func setToneSlider(_ slider: ToneSlider, to value: Double) {
        if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: "tone.\(slider.id)") }
        model.applyToSelection({ slider.edit($0, to: value) }, actionName: ToneSlider.actionName)
    }

    /// A double-click on a tone row: that one value back to each frame's OWN preset, so a
    /// selection that mixes tones resets each frame to its own.
    private func resetToneSlider(_ slider: ToneSlider) {
        model.applyToSelection({ slider.reset($0) }, actionName: ToneSlider.actionName)
    }

    /// Writes the Stretch over the whole selection, Full stored as nil (`StretchControl.edit`).
    private func setStretch(to percent: Double) {
        if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: "tone.stretch") }
        model.applyToSelection({ StretchControl.edit($0, to: percent) },
                               actionName: StretchControl.actionName)
    }

    /// A double-click on the Stretch row: every selected frame back to Full.
    private func resetStretch() {
        model.applyToSelection({ StretchControl.reset($0) }, actionName: StretchControl.actionName)
    }

    /// Each selected frame's Stretch reading from its last render, lead frame first, for the
    /// Tone icon's thin warning. nil for a frame whose render has not landed, which reads as
    /// not thin, so the icon never warns on a guess.
    private var stretchReadings: [StretchReading?] {
        var frames = model.selectedFrames
        if let lead = leadFrame, let i = frames.firstIndex(where: { $0.id == lead.id }) {
            frames.insert(frames.remove(at: i), at: 0)
        }
        return frames.map { model.renders.analysis(for: $0.id)?.stretch }
    }

    /// A slider row's reset, from its double click or its reset mark. Through the coalescer,
    /// so a double-click reset and the two presses of that double click are one undo step.
    private func rowReset(_ body: () -> Void) {
        if let coalescer { coalescer.reset(body) } else { body() }
    }

    /// Writes one control to every selected frame as an ABSOLUTE value, including when the
    /// frames disagreed beforehand. The alternative, nudging each frame by the same delta,
    /// gives a different answer depending on which frame the slider happened to be showing
    /// and cannot be undone by putting the slider back.
    private func setEnhance(_ control: EnhanceControl, to value: Double) {
        if let lead = leadFrame { SliderLatency.shared.edited(frame: lead.id, control: control.id) }
        model.applyToSelection({ sidecar in
            let current = sidecar.enhance ?? .identity
            let updated = control.setting(current, to: value)
            guard updated != current else { return sidecar }
            return SidecarEdits.setEnhance(sidecar, updated)
        }, actionName: control.label)
    }

    // MARK: histogram

    @ViewBuilder
    private func histogramSection(_ frame: Frame) -> some View {
        // Folds from its title like every other section, with no switch of its own. The
        // View menu's Show Histogram flips this fold (`AppModel.histogramOpen`).
        //
        // Closed, the body is EMPTY, and an empty Section in a grouped Form draws no card
        // and contributes no section gap, so its header butts straight into the next
        // header ("Histogram" large with "Enhance" crushed underneath it). The fix is the
        // one every fold uses: no dummy row, the gap paid by hand under the header with
        // `foldedGap`, and only while closed, when there is no card to pay it. Closed,
        // nothing is computed for it either: `absorbFreshPixels` builds no histogram.
        Section {
            if isOpen(.histogram) {
                HistogramView(histogram: histogram)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                if let histogram {
                    // A short caption, megapixels and bits. `sampleCount` is how many pixels
                    // the histogram actually counted after striding, not the frame's
                    // resolution, so it is labeled "sampled" rather than being passed off as
                    // the negative's megapixels.
                    Text(histogram.shortCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Self.foldHeader(.histogram, open: isOpen(.histogram)) { model.toggleSection(.histogram) }
        }
    }

    /// What the missing card and section gap cost when the histogram is off, paid under the
    /// header so "Enhance" lands where it would below any other section. A gap of 23
    /// measures 36 pt against 31 at an ordinary boundary, and 18 measures 30. 19 reads 31 in
    /// AX.
    static let histogramOffGap: CGFloat = 19

    // MARK: folding (2026-09-30)

    /// Whether a part is unfolded, from the app-wide preference.
    private func isOpen(_ section: InspectorSection) -> Bool {
        model.prefs.sectionFold.isOpen(section)
    }

    /// What a folded part pays under its header for the card and section gap its empty
    /// body no longer draws: the histogram's measured figure, since it is the same missing
    /// card. Nothing while the part is open.
    private func foldedGap(_ section: InspectorSection) -> CGFloat {
        Self.foldedGap(open: isOpen(section))
    }

    static func foldedGap(open: Bool) -> CGFloat { open ? 0 : histogramOffGap }

    /// The header of a section with nothing on its title line but the title: Histogram and
    /// Metadata. The title in the one section style, folding its part, in the same
    /// slot height as a header with a Reset, and paying the missing card's gap while closed.
    static func foldHeader(_ section: InspectorSection, open: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack {
            FoldTitle(section.title, open: open, action: action) {
                Self.sectionTitle(section.title)
            }
            Spacer()
        }
        .frame(height: InspectorView.headerSlotHeight)
        .padding(.bottom, foldedGap(open: open))
    }

    // MARK: the pixels the histogram and the signpost both watch

    /// The request the frame's current state wants.
    private var desiredRequest: RenderRequest? {
        guard let leadFrame else { return nil }
        return model.renders.request(for: leadFrame)
    }

    /// The request behind the cached image, but only when it matches what the state wants.
    /// Nil means the pixels on screen are stale, which is exactly the interval the slider
    /// latency measures.
    private var freshRequest: RenderRequest? {
        guard let leadFrame, let desired = desiredRequest,
              let entry = model.renders.entry(for: leadFrame.id), entry.request == desired else { return nil }
        return entry.request
    }

    private func absorbFreshPixels() {
        guard let leadFrame, let desired = desiredRequest,
              let entry = model.renders.entry(for: leadFrame.id), entry.request == desired else {
            Self.trace("absorb skipped: frame=\(leadFrame?.name ?? "nil") desired=\(desiredRequest != nil) cached=\(leadFrame.flatMap { model.renders.entry(for: $0.id) } != nil)")
            return
        }
        if let ms = SliderLatency.shared.pixelsLanded(frame: leadFrame.id) { lastLatencyMS = ms }
        guard isOpen(.histogram) else { return }
        histogram = FrameHistogram(image: entry.image)
        Self.reportViewPath(frame: leadFrame, histogram: histogram)
    }

    /// Evidence that the histogram came through the VIEW, not through the bench calling
    /// the same function. Under FP_SIGNPOST_LOG it prints once per app run, which is what
    /// stands in for a screenshot.
    private static var traceCount = 0
    static func trace(_ message: String) {
        guard traceCount < 6, ProcessInfo.processInfo.environment["FP_SIGNPOST_LOG"] == "1" else { return }
        traceCount += 1
        print("[view] \(message)")
        fflush(stdout)
    }

    private static var reportedViewPath = false
    private static func reportViewPath(frame: Frame, histogram: FrameHistogram?) {
        guard !reportedViewPath, ProcessInfo.processInfo.environment["FP_SIGNPOST_LOG"] == "1" else { return }
        reportedViewPath = true
        if let histogram {
            print("[view] InspectorView drew \(frame.name): histogram \(histogram.sampleCount) samples at "
                  + "\(histogram.bitsPerComponent) bits, peak \(histogram.peak)")
        } else {
            print("[view] InspectorView drew \(frame.name) but the histogram was refused")
        }
        fflush(stdout)
    }

    // MARK: shared bits

}

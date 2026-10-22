import SwiftUI

/// A year of ISO weeks, eight across: each sealed week as its photo (or the dusk fill with its
/// number), past weeks as hairline outlines, the weeks ahead dashed, and this week ringed in the
/// dusk glow. Below, the predictions whose day has come. `open` gets a tapped week's Sunday: a
/// sealed week, or one whose deck waits unfiled.
struct YearOfWeeksView: View {
    let model: WeeksModel
    let open: (String) -> Void

    @State private var year: Int

    private let palette = DeckPalette.week
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    init(model: WeeksModel, open: @escaping (String) -> Void) {
        self.model = model
        self.open = open
        _year = State(initialValue: model.currentYear)
    }

    private var tiles: [(weekEnding: String, number: Int, state: WeekTileState)] {
        WeeksModel.tiles(year: year, today: model.now(), records: model.recordDates, photos: model.photoDates, decks: model.unfiledDecks)
    }

    var body: some View {
        let tiles = tiles
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(reviewed: tiles.filter { if case .reviewed = $0.state { true } else { false } }.count, total: tiles.count)
                if let loadError = model.loadError {
                    Text(verbatim: loadError)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.top, 8)
                }
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(tiles, id: \.weekEnding) { tile in
                        tileView(tile)
                    }
                }
                .padding(.top, 16)
                if !model.duePredictions.isEmpty {
                    predictionsDue.padding(.top, 32)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle("Your year in weeks")
        .task {
            await model.load()
            await model.loadDuePredictions()
        }
    }

    // MARK: Header

    private func header(reviewed: Int, total: Int) -> some View {
        let years = model.years
        let index = years.firstIndex(of: year)
        return HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: String(year))
                    .font(AppFont.display(style: .largeTitle, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(reviewed) of \(total) weeks")
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if years.count > 1 {
                yearButton("chevron.left", label: "Previous year", to: index.flatMap { $0 > 0 ? years[$0 - 1] : nil })
                yearButton("chevron.right", label: "Next year", to: index.flatMap { $0 + 1 < years.count ? years[$0 + 1] : nil })
            }
        }
    }

    private func yearButton(_ symbol: String, label: String, to target: Int?) -> some View {
        Button {
            if let target { year = target }
        } label: {
            Image(systemName: symbol)
                .font(AppFont.body(weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(target == nil)
        .accessibilityLabel(Text(verbatim: target.map { "\(label), \($0)" } ?? label))
    }

    // MARK: Tiles

    @ViewBuilder
    private func tileView(_ tile: (weekEnding: String, number: Int, state: WeekTileState)) -> some View {
        let opens = isOpenable(tile)
        let face = tileFace(tile)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken(tile)))
        if opens {
            Button { open(tile.weekEnding) } label: { face.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            face
        }
    }

    private func isOpenable(_ tile: (weekEnding: String, number: Int, state: WeekTileState)) -> Bool {
        switch tile.state {
        case .reviewed, .unreviewed(hasDeck: true): true
        case .current: model.unfiledDecks.contains(tile.weekEnding)
        case .unreviewed(hasDeck: false), .future: false
        }
    }

    @ViewBuilder
    private func tileFace(_ tile: (weekEnding: String, number: Int, state: WeekTileState)) -> some View {
        let shape = RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous)
        switch tile.state {
        case .reviewed(let hasPhoto):
            if hasPhoto {
                WeekPhotoImage(server: model.server, sessionID: model.sessionID, path: WeeksModel.photoPath(tile.weekEnding),
                               version: model.photoVersion(for: tile.weekEnding), thumbnailPixels: 160,
                               load: { await model.photoData(path: $0) }) { numberFill(tile.number) }
            } else {
                numberFill(tile.number)
            }
        case .unreviewed(let hasDeck):
            shape.strokeBorder(Color.hxSeparator, lineWidth: 1)
                .overlay {
                    if hasDeck {
                        Circle().fill(palette.ink).frame(width: 5, height: 5)
                    }
                }
        case .future:
            shape.strokeBorder(Color.hxSeparator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        case .current:
            shape.strokeBorder(palette.ink, lineWidth: 2)
                .background(palette.colors.wash, in: shape)
        }
    }

    private func numberFill(_ number: Int) -> some View {
        RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous)
            .fill(palette.colors.card)
            .overlay {
                Text(verbatim: "\(number)")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
    }

    private func spoken(_ tile: (weekEnding: String, number: Int, state: WeekTileState)) -> String {
        let week = "Week \(tile.number), ending \(DailyDeckPaths.label(tile.weekEnding))"
        switch tile.state {
        case .reviewed(let hasPhoto): return "\(week), sealed\(hasPhoto ? ", with a photo" : "")"
        case .unreviewed(let hasDeck): return "\(week), not reviewed\(hasDeck ? ", its review is waiting" : "")"
        case .future: return "\(week), ahead"
        case .current: return "\(week), this week"
        }
    }

    // MARK: Predictions due

    private var predictionsDue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HXSectionHeader(title: "Predictions due")
                .padding(.bottom, 6)
            ForEach(Array(model.duePredictions.enumerated()), id: \.element.id) { index, prediction in
                if index > 0 { WeekHairline(palette: palette) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: prediction.text)
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(verbatim: "due \(DailyDeckPaths.label(prediction.due))")
                        .font(AppFont.footnote())
                        .foregroundStyle(palette.ink)
                        .monospacedDigit()
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

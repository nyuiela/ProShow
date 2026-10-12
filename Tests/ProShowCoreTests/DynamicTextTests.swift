#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct DynamicTextTests {
    private let noon = Date(timeIntervalSince1970: 1_685_620_800)

    @Test
    func clockAndDate_useObjectFormat() {
        let clock = CanvasObject(name: "Time", kind: .systemClock, bounds: .centered(width: 400, height: 80), token: "HH:mm")
        let date = CanvasObject(name: "Date", kind: .systemDate, bounds: .centered(width: 800, height: 80), token: "MMMM d, yyyy")
        let context = DynamicTextContext.empty.ticking(now: noon)
        #expect(DynamicTextEngine.resolve(clock, context: context) == "12:00")
        #expect(DynamicTextEngine.resolve(date, context: context) == "June 1, 2023")
    }

    @Test
    func textField_showsBracketsUntilFilled() {
        var object = CanvasObject(name: "Speaker", kind: .textField, bounds: .centered(width: 800, height: 80), token: "Speaker")
        object.text = ""
        let empty = DynamicTextContext.empty
        #expect(DynamicTextEngine.resolve(object, context: empty) == "[Speaker]")
        var filled = empty
        filled.fields = ["Speaker": "Pastor James"]
        #expect(DynamicTextEngine.resolve(object, context: filled) == "Pastor James")
    }

    @Test
    func interpolation_mixesTimeFieldAndQuote() {
        let box = CanvasObject(
            name: "Lower Third",
            kind: .text,
            bounds: .centered(width: 1600, height: 80),
            text: "Welcome {Speaker} · {time:h:mm a} · {quote:AAPL}"
        )
        var context = DynamicTextContext.empty.ticking(now: noon)
        context.fields = ["Speaker": "Ada"]
        context.quotes = [
            "AAPL": LiveQuote(
                symbol: "AAPL",
                name: "Apple",
                price: 190.25,
                changePercent: 1.5,
                currency: "USD",
                kind: .stock,
                updatedAt: noon
            )
        ]
        let resolved = DynamicTextEngine.resolve(box, context: context)
        #expect(resolved.contains("Ada"))
        #expect(resolved.contains("12:00 PM"))
        #expect(resolved.contains("AAPL"))
        #expect(resolved.contains("$190.25"))
        #expect(resolved.contains("+1.50%"))
    }

    @Test
    func liveQuote_expandsQuoteDirectivesInText() {
        var object = CanvasObject(
            name: "Quotes",
            kind: .liveQuote,
            bounds: .centered(width: 1200, height: 80),
            text: "{quote:AAPL} {quote:AMZN} {quote:BTC}",
            token: "stock|AAPL"
        )
        var context = DynamicTextContext.empty.ticking(now: noon)
        context.quotes = [
            "AAPL": LiveQuote(symbol: "AAPL", name: "Apple", price: 190, changePercent: 1.2, currency: "USD", kind: .stock, updatedAt: noon),
            "AMZN": LiveQuote(symbol: "AMZN", name: "Amazon", price: 180, changePercent: -0.5, currency: "USD", kind: .stock, updatedAt: noon),
            "BTC": LiveQuote(symbol: "BTC", name: "Bitcoin", price: 64_000, changePercent: 2.1, currency: "USD", kind: .crypto, updatedAt: noon),
        ]
        let resolved = DynamicTextEngine.resolve(object, context: context)
        #expect(!resolved.contains("{quote:"))
        #expect(resolved.contains("AAPL"))
        #expect(resolved.contains("AMZN"))
        #expect(DynamicTextEngine.isQuoteDirectiveTemplate(object.text))
        object.textLayout.scrolling = true
        #expect(DynamicTextEngine.loopScrollText(for: object, resolved: resolved).isEmpty)
    }

    @Test
    func loopScrollText_emptyForTokenDisplayTemplate() {
        var object = CanvasObject(
            name: "Quote",
            kind: .liveQuote,
            bounds: .centered(width: 400, height: 120),
            text: "{symbol}\n{price}\n{change}",
            token: "stock|AAPL"
        )
        object.textLayout.scrolling = true
        let resolved = "AAPL\n$190\n+1.2%"
        #expect(DynamicTextEngine.loopScrollText(for: object, resolved: resolved).isEmpty)
    }

    #if canImport(AppKit)
    @Test
    func liveQuoteTemplate_colorsChangeToken() {
        let object = CanvasObject(
            name: "Quote",
            kind: .liveQuote,
            bounds: .centered(width: 400, height: 120),
            text: "{symbol}\n{price}\n{change}",
            token: "stock|AAPL"
        )
        var context = DynamicTextContext.empty
        context.quotes = [
            "AAPL": LiveQuote(
                symbol: "AAPL",
                name: "Apple",
                price: 190,
                changePercent: 2.4,
                currency: "USD",
                kind: .stock,
                updatedAt: Date()
            ),
        ]
        let attributed = LiveQuoteTemplateRenderer.makeAttributedString(
            object: object,
            scale: 1,
            context: context
        )
        #expect(attributed != nil)
        var sawGreen = false
        attributed?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed!.length)) { value, range, _ in
            guard let color = value as? NSColor, range.length > 0 else { return }
            let body = (attributed!.string as NSString).substring(with: range)
            if body.contains("▲"), color.hexStringForLiveQuoteTests == TickerColorConfig().upColor.hexStringForLiveQuoteTests {
                sawGreen = true
            }
        }
        #expect(sawGreen)
        #expect(attributed?.string.contains("AAPL") == true)
        #expect(attributed?.string.contains("▲") == true)
    }
    #endif

    @Test
    func quote_unfilledShowsEmDash() {
        let quote = CanvasObject(
            name: "Quote",
            kind: .liveQuote,
            bounds: .centered(width: 800, height: 80),
            text: LiveQuoteCatalog.defaultTemplate,
            token: "crypto|BTC"
        )
        let resolved = DynamicTextEngine.resolve(quote, context: .empty)
        #expect(resolved.contains("BTC"))
        #expect(resolved.contains("—"))
    }

    @Test
    func fieldKeys_andQuoteRequests_scanCanvas() {
        let field = CanvasObject(name: "Sermon", kind: .textField, bounds: .centered(width: 200, height: 40), token: "Sermon Title")
        let text = CanvasObject(name: "Mix", kind: .text, bounds: .centered(width: 200, height: 40), text: "Hi {Host} {quote:ETH}")
        let quote = CanvasObject(name: "AAPL", kind: .liveQuote, bounds: .centered(width: 200, height: 40), token: "stock|AAPL")
        let keys = DynamicTextEngine.fieldKeys(in: [field, text, quote])
        #expect(keys.contains("Sermon Title"))
        #expect(keys.contains("Host"))
        let requests = DynamicTextEngine.quoteRequests(in: [field, text, quote])
        #expect(requests.contains(where: { $0.kind == .stock && $0.symbol == "AAPL" }))
        #expect(requests.contains(where: { $0.kind == .crypto && $0.normalizedSymbol == "ethereum" }))
    }

    @Test @MainActor
    func addLiveObjects_areTextLike() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let time = engine.addObject(.systemClock)
        let date = engine.addObject(.systemDate)
        let quote = engine.addObject(.liveQuote)
        let field = engine.addObject(.textField)
        let countdown = engine.addObject(.timerCountdown)
        #expect(time.isTextLike)
        #expect(date.isTextLike)
        #expect(quote.isTextLike)
        #expect(field.isTextLike)
        #expect(countdown.isTextLike)
        #expect(time.token == "h:mm:ss a")
        #expect(date.token == "EEEE, MMMM d")
        #expect(quote.token.contains("AAPL"))
        #expect(field.token == "Speaker")
        #expect(countdown.token == CountdownFormatCatalog.default)
    }

    @Test
    func countdown_usesBoundTimerAndFormat() {
        let timer = InspectorTimer(id: ActionSeedID.serviceTimer, name: "Program Timer", durationSeconds: 75, remainingSeconds: 75)
        var object = CanvasObject(
            name: "Countdown",
            kind: .timerCountdown,
            bounds: .centered(width: 400, height: 80),
            token: "m:ss",
            timerID: timer.id
        )
        var context = DynamicTextContext.empty
        context.timers = [timer]
        #expect(DynamicTextEngine.resolve(object, context: context) == "1:15")
        object.token = "HH:mm:ss"
        #expect(DynamicTextEngine.resolve(object, context: context) == "00:01:15")
        object.token = "s"
        #expect(DynamicTextEngine.resolve(object, context: context) == "75")
        let other = InspectorTimer(id: UUID(), name: "Hold", durationSeconds: 9, remainingSeconds: 9)
        context.timers = [other, timer]
        object.token = "mm:ss"
        #expect(DynamicTextEngine.resolve(object, context: context) == "01:15")
    }

    @Test
    func countdown_canFollowProgramMediaRemaining() {
        var object = CanvasObject(
            name: "Countdown",
            kind: .timerCountdown,
            bounds: .centered(width: 400, height: 80),
            token: "m:ss"
        )
        object.countdownValueSource = .programMedia
        var context = DynamicTextContext.empty
        context.timers = [InspectorTimer(name: "Program Timer", durationSeconds: 900, remainingSeconds: 900)]
        context.mediaRemainingSeconds = 95
        context.mediaDurationSeconds = 180
        #expect(DynamicTextEngine.resolve(object, context: context) == "1:35")
        object.countdownValueSource = .timer
        #expect(DynamicTextEngine.resolve(object, context: context) == "15:00")
    }

    @Test @MainActor
    func addCountdown_bindsProgramTimer() {
        let controller = TestSupport.sampleController()
        controller.editors.open(.presentation, show: controller.show, selectedSlideID: controller.selectedSlideID)
        let added = controller.editors.addObject(.timerCountdown)
        controller.finishAddingLiveObject(added)
        #expect(added.token == CountdownFormatCatalog.default)
        let bound = controller.editors.selectedObjects.first
        #expect(bound?.timerID == ActionSeedID.serviceTimer)
        #expect(controller.inspector.startTimer(id: ActionSeedID.serviceTimer))
        #expect(controller.inspector.timer(id: ActionSeedID.serviceTimer)?.isRunning == true)
        #expect(controller.inspector.stopTimer(id: ActionSeedID.serviceTimer))
        #expect(controller.inspector.timer(id: ActionSeedID.serviceTimer)?.isRunning == false)
    }

    @Test @MainActor
    func fillTextField_updatesControllerSlot() {
        let controller = TestSupport.sampleController()
        controller.ensureTextField(key: "Speaker")
        controller.setTextField("Speaker", value: "Maya")
        #expect(controller.textFields.contains(where: { $0.key == "Speaker" && $0.value == "Maya" }))
        var object = CanvasObject(name: "Speaker", kind: .textField, bounds: .centered(width: 200, height: 40), token: "Speaker")
        object.text = ""
        #expect(DynamicTextEngine.resolve(object, context: controller.dynamicTextContext()) == "Maya")
    }

    @Test
    func requiredLiveQuotes_areScopedPerObject() {
        let aapl = CanvasObject(name: "A", kind: .liveQuote, bounds: .centered(width: 100, height: 40), token: "AAPL")
        let msft = CanvasObject(name: "B", kind: .liveQuote, bounds: .centered(width: 100, height: 40), token: "MSFT")
        let aaplOnly = DynamicTextEngine.requiredLiveQuoteRequests(for: aapl, canvasObjects: [aapl, msft])
        #expect(aaplOnly.count == 1)
        #expect(aaplOnly.first?.symbol == "AAPL")
    }

    @Test
    func programLiveQuote_defersUntilQuoteLoaded() {
        let object = CanvasObject(
            name: "Quote",
            kind: .liveQuote,
            bounds: .centered(width: 400, height: 80),
            token: "stock|AAPL"
        )
        let empty = DynamicTextContext.empty
        #expect(
            DynamicTextEngine.shouldDeferProgramLiveQuoteOutput(
                object: object,
                context: empty,
                canvasObjects: [object]
            )
        )
        var loaded = empty
        loaded.quotes = [
            "AAPL": LiveQuote(
                symbol: "AAPL",
                name: "Apple",
                price: 190,
                changePercent: 1.2,
                currency: "USD",
                kind: .stock,
                updatedAt: Date()
            ),
        ]
        #expect(
            !DynamicTextEngine.shouldDeferProgramLiveQuoteOutput(
                object: object,
                context: loaded,
                canvasObjects: [object]
            )
        )
    }

    @Test
    func programLiveQuote_showsPlaceholdersAfterInitialFetchEvenWhenUnresolved() {
        let object = CanvasObject(
            name: "Quote",
            kind: .liveQuote,
            bounds: .centered(width: 400, height: 80),
            token: "stock|AAPL"
        )
        var fetched = DynamicTextContext.empty
        fetched.liveQuotesInitialLoadPending = false
        #expect(
            !DynamicTextEngine.shouldDeferProgramLiveQuoteOutput(
                object: object,
                context: fetched,
                canvasObjects: [object]
            )
        )
    }

    @Test
    func xlmTicker_resolvesToStellarCryptoId() {
        let fromTicker = LiveQuoteRequest(symbol: "XLM", kind: .inferred(from: "XLM"))
        #expect(fromTicker.kind == .crypto)
        #expect(fromTicker.normalizedSymbol == "stellar")
        let fromText = DynamicTextEngine.quoteRequests(in: [
            CanvasObject(name: "T", kind: .text, bounds: .centered(width: 100, height: 40), text: "{quote:XLM}"),
        ])
        #expect(fromText.contains(where: { $0.kind == .crypto && $0.normalizedSymbol == "stellar" }))
    }

    @Test
    func hasResolvedLiveQuote_matchesByQuoteValueWhenDictionaryKeyDiffers() {
        var context = DynamicTextContext.empty
        context.quotes = [
            "bitcoin": LiveQuote(
                symbol: "bitcoin",
                name: "Bitcoin",
                price: 60_000,
                changePercent: 1,
                currency: "USD",
                kind: .crypto,
                updatedAt: Date()
            ),
        ]
        let request = LiveQuoteRequest(symbol: "BTC", kind: .crypto)
        #expect(DynamicTextEngine.hasResolvedLiveQuote(request, in: context))
    }

    @Test @MainActor
    func liveCanvasObjects_includesActivePropQuotes() {
        let controller = TestSupport.sampleController()
        var prop = controller.inspector.addProp(name: "Ticker Prop")
        prop.elements = [
            CanvasObject(
                name: "Quote",
                kind: .liveQuote,
                bounds: .centered(width: 400, height: 80),
                token: "stock|MSFT"
            ),
        ]
        if let index = controller.inspector.props.firstIndex(where: { $0.id == prop.id }) {
            controller.inspector.props[index].elements = prop.elements
        }
        let before = DynamicTextEngine.quoteRequests(in: controller.liveCanvasObjects())
        #expect(before.isEmpty)
        #expect(controller.toggleInspectorProp(id: prop.id))
        let after = DynamicTextEngine.quoteRequests(in: controller.liveCanvasObjects())
        #expect(after.contains(where: { $0.symbol == "MSFT" }))
    }

    @Test @MainActor
    func quoteEngine_usesInjectedProvider() async {
        let engine = LiveQuoteEngine(provider: StubQuoteProvider())
        engine.minimumInterval = 0
        engine.tick(needed: [LiveQuoteRequest(symbol: "AAPL", kind: .stock)], now: Date())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.quotes["AAPL"]?.price == 123.45)
    }

    @Test
    func outlineMediaAndGraphTokens_resolveFromOneContext() {
        var context = DynamicTextContext.empty
        context.outline = OutlineLinkState(
            segmentLink: "https://example.com/keynote",
            segmentTitle: "Opening Keynote",
            speakerName: "Jane Doe",
            speakerRole: "Host",
            speakerOrganization: "Northwind",
            plannedDurationSeconds: 720,
            plannedEnd: noon,
            nextTitle: "Worship Set",
            nextSpeakerName: "A. Kim",
            upcoming: [
                OutlineAgendaItem(title: "Worship Set", speakerName: "A. Kim"),
                OutlineAgendaItem(title: "Q&A", speakerName: ""),
                OutlineAgendaItem(title: "Close", speakerName: "Jane Doe"),
                OutlineAgendaItem(title: "Overflow", speakerName: "Sam"),
            ]
        )
        context.mediaLink = MediaLinkState(name: "Opener.mov", remainingSeconds: 90, elapsedSeconds: 30, durationSeconds: 120)
        context.broadcastTimecode = "01:02:03"
        context.graphValues = ["score.home": "14"]
        context.fields["speaker.name"] = "Stale Manual"

        var box = CanvasObject(name: "Lower Third", kind: .text, bounds: .centered(width: 900, height: 200))
        box.text = "Speaking Now: {speaker.name} · {speaker.role} · {segment.title} · {segment.link} · {segment.duration:mm:ss} · {next.title} · {next.speaker} · {media.name} {media.remaining:mm:ss} {timecode} {graph:score.home}\n{agenda:2}"
        let resolved = DynamicTextEngine.resolve(box, context: context)
        #expect(resolved.contains("https://example.com/keynote"))
        #expect(resolved.contains("Speaking Now: Jane Doe"))
        #expect(!resolved.contains("Stale Manual"))
        #expect(resolved.contains("Host"))
        #expect(resolved.contains("Opening Keynote"))
        #expect(resolved.contains("12:00"))
        #expect(resolved.contains("Worship Set"))
        #expect(resolved.contains("A. Kim"))
        #expect(resolved.contains("Opener.mov"))
        #expect(resolved.contains("01:30"))
        #expect(resolved.contains("01:02:03"))
        #expect(resolved.contains("14"))
        #expect(resolved.contains("Worship Set — A. Kim\nQ&A"))
        #expect(!resolved.contains("Overflow"))

        box.text = "{speaker.name}"
        context.outline.speakerName = ""
        context.fields["speaker.name"] = "Manual Host"
        #expect(DynamicTextEngine.resolve(box, context: context) == "Manual Host")

        box.text = "Speaking Now: {speaker.name}"
        context.fields["speaker.name"] = ""
        #expect(DynamicTextEngine.resolve(box, context: context) == "Speaking Now: ")

        box.text = "{not.a.token}"
        #expect(DynamicTextEngine.resolve(box, context: context) == "{not.a.token}")

        box.text = "{segment.title} {agenda:3}"
        let keys = DynamicTextEngine.fieldKeys(in: [box])
        #expect(!keys.contains("segment.title"))
        #expect(!keys.contains("agenda:3"))
    }
}

#if canImport(AppKit)
import AppKit

private extension NSColor {
    var hexStringForLiveQuoteTests: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
#endif

private struct StubQuoteProvider: LiveQuoteProviding {
    func fetchQuotes(_ requests: [LiveQuoteRequest]) async -> [LiveQuote] {
        requests.map {
            LiveQuote(
                symbol: $0.normalizedSymbol,
                name: $0.symbol,
                price: 123.45,
                changePercent: 0.5,
                currency: "USD",
                kind: $0.kind,
                updatedAt: Date()
            )
        }
    }

    @Test
    func interpolate_supportsDoubleBraceAndTimerAliases() {
        var context = DynamicTextContext.empty
        context.fields["speaker.name"] = "Alex Rivera"
        context.fields["speaker.title"] = "Host"
        let timer = InspectorTimer(name: "Segment", durationSeconds: 120, remainingSeconds: 45, isRunning: true)
        context.timers = [timer]

        var box = CanvasObject(name: "Lower Third", kind: .text, bounds: .centered(width: 800, height: 120))
        box.text = "{{speaker.name}} — {{speaker.title}} · {{timer.countdown}}"
        let resolved = DynamicTextEngine.resolve(box, context: context)
        #expect(resolved.contains("Alex Rivera"))
        #expect(resolved.contains("Host"))
        #expect(resolved.contains("0:45") || resolved.contains(":45"))
    }
}

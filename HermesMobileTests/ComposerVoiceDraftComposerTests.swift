import AVFoundation
import UIKit
import XCTest
@testable import HermesMobile

final class ComposerVoiceDraftComposerTests: XCTestCase {
    func testComposerSendKeyboardCommandIsDiscoverableCommandReturn() {
        XCTAssertEqual(ComposerKeyboardCommand.title, "Send Message")
        XCTAssertEqual(ComposerKeyboardCommand.input, "\r")
        XCTAssertEqual(ComposerKeyboardCommand.modifierFlags, .command)
    }

    func testVoiceInputCannotStartBehindAppLockEvenInAnActiveScene() {
        XCTAssertFalse(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: true))
        XCTAssertTrue(ComposerVoiceInputStartPolicy.canStart(appIsActive: true, appIsLocked: false))
    }

    func testComposedDraftUsesTranscriptWhenDraftIsEmpty() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "", transcript: "Open the workspace"),
            "Open the workspace"
        )
    }

    func testComposedDraftAppendsTranscriptToExistingDraft() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "Please", transcript: "summarize this file"),
            "Please summarize this file"
        )
    }

    func testComposedDraftPreservesBaseDraftWhenTranscriptIsBlank() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "Keep this", transcript: "   \n"),
            "Keep this"
        )
    }

    func testDraftUpdateSessionComposesWhileAcceptingUpdates() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Please")

        XCTAssertEqual(session.composedDraft(for: "summarize this file", endsSegment: true), "Please summarize this file")
    }

    func testDraftUpdateSessionIgnoresLateTranscriptAfterStop() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Send this")
        session.stopAcceptingUpdates()

        XCTAssertNil(session.composedDraft(for: "late final transcript", endsSegment: true))
    }

    func testDraftUpdateSessionUsesNewBaseDraftAfterRestart() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Old")
        session.stopAcceptingUpdates()
        session.begin(baseDraft: "New")

        XCTAssertEqual(session.composedDraft(for: "transcript", endsSegment: true), "New transcript")
    }

    func testDraftUpdateSessionGrowsPartialsWithinASegment() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "")

        XCTAssertEqual(session.composedDraft(for: "we can", endsSegment: false), "we can")
        XCTAssertEqual(session.composedDraft(for: "we can use pinned", endsSegment: false), "we can use pinned")
    }

    func testDraftUpdateSessionKeepsFinishedSegmentWhenANewOneStarts() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "")
        session.composedDraft(for: "we can use pinned models", endsSegment: true)

        XCTAssertEqual(
            session.composedDraft(for: "until we're ready", endsSegment: false),
            "we can use pinned models until we're ready"
        )
    }

    func testDraftUpdateSessionKeepsPreviousSegmentWithoutAnEndSignal() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "")
        session.composedDraft(for: "we can use pinned models", endsSegment: false)

        // No metadata flag: the new transcript shares no leading word and is
        // under half the length, so the previous segment is committed anyway.
        XCTAssertEqual(session.composedDraft(for: "until", endsSegment: false), "we can use pinned models until")
    }

    func testDraftUpdateSessionRevisesTheOpenSegmentInPlace() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "")
        session.composedDraft(for: "we can use pin", endsSegment: false)

        // A revision of the same segment replaces it instead of duplicating it.
        XCTAssertEqual(session.composedDraft(for: "we can use pinned", endsSegment: false), "we can use pinned")
    }

    func testDraftUpdateSessionKeepsABaseDraftTypedBeforeDictation() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Please")
        session.composedDraft(for: "we can use pinned models", endsSegment: true)

        XCTAssertEqual(
            session.composedDraft(for: "until we're ready", endsSegment: false),
            "Please we can use pinned models until we're ready"
        )
    }

    func testDraftUpdateSessionDoesNotRepeatASegmentWhenTheTranscriptKeepsIt() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "")
        session.composedDraft(for: "we can use pinned models", endsSegment: true)

        // A recognizer that keeps the whole transcript across the pause.
        XCTAssertEqual(
            session.composedDraft(for: "We can use pinned models until", endsSegment: false),
            "we can use pinned models until"
        )
        XCTAssertEqual(
            session.composedDraft(for: "We can use pinned models until we're ready.", endsSegment: true),
            "we can use pinned models until we're ready."
        )
    }

    func testDraftUpdateSessionIgnoresAFinalResultRepeatingTheLastSegment() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "")
        session.composedDraft(for: "we can use pinned models", endsSegment: true)
        session.composedDraft(for: "until we're ready", endsSegment: true)

        XCTAssertEqual(
            session.composedDraft(for: "until we're ready", endsSegment: true),
            "we can use pinned models until we're ready"
        )
    }

    func testDraftUpdateSessionStillBlocksLateUpdatesAfterACommit() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Send this")
        session.composedDraft(for: "the file", endsSegment: true)
        session.stopAcceptingUpdates()

        XCTAssertNil(session.composedDraft(for: "late", endsSegment: false))
    }

    func testVoiceInputPreflightAcceptsValidInputFormatValues() {
        XCTAssertNoThrow(
            try ComposerVoiceInputPreflight.validate(sampleRate: 44_100, channelCount: 1)
        )
    }

    func testVoiceInputPreflightRejectsZeroSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: 0, channelCount: 1)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsInfiniteSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: .infinity, channelCount: 1)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooLowSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: ComposerVoiceInputPreflight.validSampleRateRange.lowerBound - 1,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooHighSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: ComposerVoiceInputPreflight.validSampleRateRange.upperBound + 1,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsZeroChannelCount() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: 44_100, channelCount: 0)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooHighChannelCount() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: 44_100,
                channelCount: ComposerVoiceInputPreflight.validChannelCountRange.upperBound + 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputAudioSessionConfigurationDoesNotDuckOtherAudio() {
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.category, .playAndRecord)
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.mode, .measurement)
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.mixWithOthers))
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.allowBluetooth))
        XCTAssertFalse(ComposerVoiceAudioSessionConfiguration.options.contains(.duckOthers))
    }

    func testVoiceInputStartPolicyAllowsActiveAppState() {
        XCTAssertTrue(ComposerVoiceInputStartPolicy.canStart(appIsActive: true))
    }

    func testVoiceInputStartPolicyRejectsInactiveAppState() {
        XCTAssertFalse(ComposerVoiceInputStartPolicy.canStart(appIsActive: false))
    }

    func testVoiceInputStartPolicyRejectsMissingAudioInput() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
                isInputAvailable: false,
                sampleRate: 44_100,
                inputNumberOfChannels: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .noAudioInput)
        }
    }

    func testVoiceInputStartPolicyRejectsInvalidSessionFormat() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
                isInputAvailable: true,
                sampleRate: 0,
                inputNumberOfChannels: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputStartPolicyRejectsRunningEngineBeforeTapInstall() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioEngine(isRunning: true)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .audioEngineAlreadyRunning)
        }
    }

    func testVoiceControlAccessibilityLabelsDescribeTheAvailableAction() {
        XCTAssertEqual(
            ComposerVoiceControlAccessibility.label(isListening: false, isRecordingVoiceNote: false),
            "Voice input"
        )
        XCTAssertEqual(
            ComposerVoiceControlAccessibility.label(isListening: true, isRecordingVoiceNote: false),
            "Stop voice input"
        )
        XCTAssertEqual(
            ComposerVoiceControlAccessibility.label(isListening: false, isRecordingVoiceNote: true),
            "Recording voice note"
        )
    }

    @MainActor
    func testVoiceInputControllerDoesNotCreateSpeechOrAudioObjectsBeforeRecording() {
        let counter = VoiceInputFactoryCounter()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in
                counter.speechRecognizerCalls += 1
                return nil
            },
            audioEngineFactory: {
                counter.audioEngineCalls += 1
                return AVAudioEngine()
            }
        )

        XCTAssertEqual(counter.speechRecognizerCalls, 0)
        XCTAssertEqual(counter.audioEngineCalls, 0)

        controller.stopKeepingTranscript()

        XCTAssertEqual(counter.speechRecognizerCalls, 0)
        XCTAssertEqual(counter.audioEngineCalls, 0)
    }

    func testSpeechLocaleCandidatesKeepCurrentFirstThenPreferredThenEnglishUS() {
        let candidates = ComposerSpeechLocalePolicy.candidates(
            current: Locale(identifier: "en_PK"),
            preferredLanguages: ["en-PK", "ur-PK", "fr-FR", "de-DE", "es-ES"]
        )

        XCTAssertEqual(
            candidates.map(\.normalizedSpeechIdentifier),
            ["en-pk", "ur-pk", "fr-fr", "de-de", "en-us"],
            "en-PK repeats the current locale, so it does not take a preferred-language slot."
        )
    }

    func testFixedLocaleIsTheOnlyCandidate() {
        let candidates = ComposerSpeechLocalePolicy.candidates(
            fixed: Locale(identifier: "zh-CN"),
            current: Locale(identifier: "en_US"),
            preferredLanguages: ["en-US"]
        )

        XCTAssertEqual(candidates.map(\.normalizedSpeechIdentifier), ["zh-cn"], "the Mandarin card never falls back to English")
    }

    func testNoFixedLocaleKeepsTheUsualCandidates() {
        XCTAssertEqual(
            ComposerSpeechLocalePolicy.candidates(fixed: nil, current: Locale(identifier: "en_US"), preferredLanguages: []),
            ComposerSpeechLocalePolicy.candidates(current: Locale(identifier: "en_US"), preferredLanguages: [])
        )
    }

    func testFixedLocaleWithoutModelHasNoRecognizer() {
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                fixed: Locale(identifier: "zh-CN"), current: Locale(identifier: "en_US"), preferredLanguages: []),
            supportedLocales: [Locale(identifier: "en-US")],
            recognizer: { $0.normalizedSpeechIdentifier }
        )

        XCTAssertNil(selected, "no zh-CN model means no mic, not English dictation")
    }

    func testSpeechLocaleCandidatesDedupeEnglishUSAcrossSeparators() {
        let candidates = ComposerSpeechLocalePolicy.candidates(
            current: Locale(identifier: "en_US"),
            preferredLanguages: ["EN-us"]
        )

        XCTAssertEqual(candidates.map(\.normalizedSpeechIdentifier), ["en-us"])
    }

    func testSpeechLocaleSelectionKeepsASupportedCurrentLocale() {
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "en_GB"),
                preferredLanguages: ["fr-FR"]
            ),
            supportedLocales: [Locale(identifier: "en-GB"), Locale(identifier: "fr-FR"), Locale(identifier: "en-US")],
            recognizer: { $0.normalizedSpeechIdentifier }
        )

        XCTAssertEqual(selected, "en-gb")
    }

    func testSpeechLocaleSelectionFallsBackPastUnsupportedAndModelLessLocales() {
        var askedFor: [String] = []
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "en_PK"),
                preferredLanguages: ["ur-PK", "fr-FR"]
            ),
            supportedLocales: [Locale(identifier: "ur-PK"), Locale(identifier: "fr_FR"), Locale(identifier: "en-US")],
            recognizer: { locale -> String? in
                askedFor.append(locale.normalizedSpeechIdentifier)
                return askedFor.last == "ur-pk" ? nil : askedFor.last
            }
        )

        XCTAssertEqual(selected, "fr-fr")
        XCTAssertEqual(askedFor, ["ur-pk", "fr-fr"], "Unsupported en_PK is never asked for a recognizer.")
    }

    func testSpeechLocaleSelectionIgnoresRegionOverrideKeywords() {
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "de_DE@rg=atzzzz"),
                preferredLanguages: []
            ),
            supportedLocales: [Locale(identifier: "de-DE"), Locale(identifier: "en-US")],
            recognizer: { $0.normalizedSpeechIdentifier }
        )

        XCTAssertEqual(selected, "de-de")
    }

    func testSpeechLocaleSelectionMatchesScriptTaggedPreferredLanguages() {
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "zh-Hans_US"),
                preferredLanguages: ["zh-Hans-CN", "zh-Hant-TW"]
            ),
            supportedLocales: [Locale(identifier: "zh-CN"), Locale(identifier: "zh-TW"), Locale(identifier: "en-US")],
            recognizer: { $0.identifier }
        )

        XCTAssertEqual(selected, "zh-CN")
    }

    func testSpeechLocaleSelectionPrefersAnExactMatchOverAVariant() {
        let supported: Set<Locale> = [
            Locale(identifier: "hi-IN-translit"),
            Locale(identifier: "hi-IN"),
            Locale(identifier: "en-US"),
        ]
        func select(current: String) -> String? {
            ComposerSpeechLocalePolicy.firstAvailable(
                in: ComposerSpeechLocalePolicy.candidates(current: Locale(identifier: current), preferredLanguages: []),
                supportedLocales: supported,
                recognizer: { $0.identifier }
            )
        }

        XCTAssertEqual(select(current: "hi_IN"), "hi-IN")
        XCTAssertEqual(select(current: "hi-IN-translit"), "hi-IN-translit")
    }

    func testSpeechLocaleSelectionReturnsNilWhenNoCandidateHasAModel() {
        let selected = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: Locale(identifier: "en_PK"),
                preferredLanguages: []
            ),
            supportedLocales: [Locale(identifier: "en-US")],
            recognizer: { _ -> String? in nil }
        )

        XCTAssertNil(selected)
    }

    func testSTTProviderPreferenceDefaultsToServerFirst() {
        XCTAssertEqual(ComposerSTTProviderPreference.defaultValue, .serverFirst)
        XCTAssertEqual(
            ComposerSTTProviderPreference.storedValue("unknown"),
            .serverFirst
        )
    }

    func testServerFirstPolicyPrefersServerThenOnDevice() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .serverFirst,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            [.server, .onDevice]
        )
    }

    func testServerFirstPolicyFallsBackToOnDeviceWhenServerIsNotConfigured() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .serverFirst,
                serverConfigured: false,
                onDeviceSupported: true
            ),
            [.onDevice]
        )
    }

    func testOnDeviceFirstPolicyFallsBackToServerWhenOnDeviceIsUnsupported() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceFirst,
                serverConfigured: true,
                onDeviceSupported: false
            ),
            [.server]
        )
    }

    func testOnDeviceOnlyPolicyNeverRoutesToServer() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            [.onDevice]
        )
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: false
            ),
            []
        )
    }

    func testProviderPolicyReturnsNextFallbackOnly() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.fallbackProvider(
                after: .server,
                preference: .serverFirst,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            .onDevice
        )
        XCTAssertNil(
            ComposerSTTProviderPolicy.fallbackProvider(
                after: .server,
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: true
            )
        )
    }
}

private extension Locale {
    var normalizedSpeechIdentifier: String {
        ComposerSpeechLocalePolicy.normalizedIdentifier(identifier)
    }
}

private final class VoiceInputFactoryCounter {
    var speechRecognizerCalls = 0
    var audioEngineCalls = 0
}

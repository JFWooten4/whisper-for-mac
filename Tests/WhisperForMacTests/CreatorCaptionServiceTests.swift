import Foundation
import Testing
@testable import WhisperForMac

@Test
func creatorVideoAcceptsURLAndIDInputs() {
    let id = "dQw4w9WgXcQ"
    #expect(CreatorVideo.parse(id)?.id == id)
    #expect(CreatorVideo.parse("https://www.youtube.com/watch?v=\(id)&t=90")?.id == id)
    #expect(CreatorVideo.parse("https://youtu.be/\(id)")?.id == id)
    #expect(CreatorVideo.parse("https://www.youtube.com/shorts/\(id)")?.id == id)
    #expect(CreatorVideo.parse("https://youtube.com/live/\(id)")?.id == id)
}

@Test
func creatorVideoRejectsOtherHostsAndMalformedIDs() {
    #expect(CreatorVideo.parse("https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ") == nil)
    #expect(CreatorVideo.parse("http://youtube.com/watch?v=dQw4w9WgXcQ") == nil)
    #expect(CreatorVideo.parse("https://www.youtube.com/playlist?list=PL123") == nil)
    #expect(CreatorVideo.parse("https://youtu.be/not_a_valid_video_id") == nil)
    #expect(CreatorVideo.parse("wrong-id") == nil)
}

@Test
func creatorVTTTextPreservesCueTextAndRemovesTiming() {
    let original = """
    WEBVTT - original captions

    NOTE A track uploaded by the creator

    00:00:00.000 --> 00:00:01.500
    <v Narrator>Hello &amp; welcome!</v>

    00:00:01.500 --> 00:00:03.250 align:start
    <c>Stellar</c> Decentralized Exchange
    10 &lt; 11
    """

    let text = CreatorCaptionText.plainText(from: original)
    #expect(text == "Hello & welcome!\nStellar Decentralized Exchange\n10 < 11")
    #expect(original.contains("00:00:01.500 -->"))
}

@Test
func creatorVTTTextHandlesEmptyOrMetadataOnlyFiles() {
    #expect(CreatorCaptionText.plainText(from: "WEBVTT\n\nNOTE no captions") == "")
}

@MainActor
@Test
func creatorSourceUsesExistingOutputPreferencesWithoutAWhisperModel() {
    let state = AppState()
    state.preferences.outputFormats = [.vtt]
    state.chooseCreatorVideo("dQw4w9WgXcQ")
    #expect(state.creatorVideo?.id == "dQw4w9WgXcQ")
    #expect(state.selectedFileURL == nil)
    #expect(state.wizardStep == .language)
    #expect(state.canStartTranscription)
    #expect(state.outputFormatsSummary == "VTT")
    #expect(state.resolvedOutputDirectory == state.preferences.customOutputDirectory)
}

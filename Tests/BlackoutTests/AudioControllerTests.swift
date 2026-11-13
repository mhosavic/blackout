import Testing
import BlackoutCore

struct AudioControllerTests {

    @Test func parsesVolumeAndMute() {
        let unmuted = AudioController.parseVolumeSettings("output volume:44, input volume:100, alert volume:100, output muted:false")
        #expect(unmuted == OutputAudio(volume: 44, muted: false))

        let muted = AudioController.parseVolumeSettings("output volume:0, input volume:50, alert volume:100, output muted:true")
        #expect(muted == OutputAudio(volume: 0, muted: true))
    }

    /// An output with no software volume (HDMI, some DACs) reports
    /// "missing value"; the long-standing fallback is 50, and it is not muted
    @Test func fallsBackWhenTheDeviceReportsNoVolume() {
        let noControl = AudioController.parseVolumeSettings("output volume:missing value, input volume:missing value, alert volume:100, output muted:missing value")
        #expect(noControl == OutputAudio(volume: 50, muted: false))
        #expect(AudioController.parseVolumeSettings("") == OutputAudio(volume: 50, muted: false))
    }

    /// "input volume" and "alert volume" also end in "volume:N"; only the
    /// output values may be read
    @Test func readsTheOutputValuesNotTheInputOnes() {
        let audio = AudioController.parseVolumeSettings("input volume:7, alert volume:9, output muted:true, output volume:61")
        #expect(audio == OutputAudio(volume: 61, muted: true))
    }
}

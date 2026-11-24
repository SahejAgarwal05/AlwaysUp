// Audio.swift — mute / unmute the built-in speakers and headphone jack (CoreAudio).

import CoreAudio
import Foundation

enum Audio {
    struct Output {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isHeadphones: Bool
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var a = addr
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    /// Built-in output devices (speakers and the headphone jack).
    static func builtInOutputs() -> [Output] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            // Has output streams?
            var sAddr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { return nil }
            // Built in?
            guard uint32(id, address(kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeBuiltIn else { return nil }
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Output"
            // Apple silicon: headphones are their own device. Intel: one device whose data source is 'hdpn'.
            let source = uint32(id, address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput))
            let headphones = name.localizedCaseInsensitiveContains("headphone") || source == 0x6864706E /* 'hdpn' */
            return Output(id: id, uid: uid, name: name, isHeadphones: headphones)
        }
    }

    /// Elements that carry a mute control: the main element, or each channel if there's no main one.
    private static func muteElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        for elems in [[kAudioObjectPropertyElementMain], [1, 2]] as [[AudioObjectPropertyElement]] {
            let ok = elems.allSatisfy { e in
                var a = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, e)
                var settable: DarwinBoolean = false
                return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
            }
            if ok { return elems }
        }
        return []
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool? {
        guard let e = muteElements(id).first else { return nil }
        return uint32(id, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, e)).map { $0 != 0 }
    }

    @discardableResult
    static func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        let elems = muteElements(id)
        guard !elems.isEmpty else { return false }
        var v: UInt32 = muted ? 1 : 0
        var ok = true
        for e in elems {
            var a = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, e)
            ok = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr && ok
        }
        return ok
    }
}

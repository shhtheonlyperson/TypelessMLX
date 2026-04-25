import AVFoundation
import CoreAudio
import Foundation
import TypelessMLXCore

/// Records audio using a fresh AVAudioEngine per session.
/// Records in native mic format — mlx-whisper handles any conversion needed.
class AudioRecorder: NSObject {
    static let shared = AudioRecorder()

    private var engine: AVAudioEngine?
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private var isCurrentlyRecording = false
    private let lock = NSLock()
    private var recordingStartedAt: Date?  // for config-change grace period
    private var lastStoppedAt: Date?
    private let restartSettleInterval: TimeInterval = 1.25

    /// Called on the audio tap thread with a normalised 0–1 level each buffer (~23ms).
    var audioLevelHandler: ((Float) -> Void)?

    /// Called on the audio tap thread with each raw PCM buffer — used by SpeechStreamer for live preview.
    var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?

    private override init() {
        super.init()
        logInfo("AudioRecorder", "Initialized (per-session AVAudioEngine)")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        guard let changedEngine = notification.object as? AVAudioEngine else { return }
        lock.lock()
        let activeEngine = engine
        let recording = isCurrentlyRecording
        let startedAt = recordingStartedAt
        lock.unlock()
        guard changedEngine === activeEngine else { return }

        // Ignore config changes within 2s of recording start — caused by our own setInputDevice() call
        if let startedAt = startedAt, Date().timeIntervalSince(startedAt) < 2.0 {
            logDebug("AudioRecorder", "Ignoring config change during startup grace period")
            return
        }
        logWarn("AudioRecorder", "Audio engine configuration changed (recording=\(recording))")
        guard recording else { return }
        do {
            changedEngine.stop()
            try changedEngine.start()
            logInfo("AudioRecorder", "Engine restarted after config change")
        } catch {
            logError("AudioRecorder", "Failed to restart engine after config change: \(error)")
            lock.lock()
            isCurrentlyRecording = false
            audioFile = nil
            engine = nil
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioDeviceLost, object: nil)
            }
        }
    }

    private func tempAudioURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "typelessmlx_\(UUID().uuidString).wav"
        return tempDir.appendingPathComponent(fileName)
    }

    @discardableResult
    func startRecording() -> Bool {
        var settleDelay: TimeInterval = 0
        lock.lock()
        guard !isCurrentlyRecording else {
            logWarn("AudioRecorder", "Already recording, ignoring startRecording")
            lock.unlock()
            return false
        }
        settleDelay = AudioRecorderRouting.restartSettleDelay(
            now: Date(),
            lastStoppedAt: lastStoppedAt,
            interval: restartSettleInterval
        )
        lock.unlock()

        if settleDelay > 0 {
            logInfo("AudioRecorder", "Waiting \(String(format: "%.2f", settleDelay))s for input device to settle")
            Thread.sleep(forTimeInterval: settleDelay)
        }

        let engine = AVAudioEngine()
        let url = tempAudioURL()
        logInfo("AudioRecorder", "Starting recording to: \(url.lastPathComponent)")

        if shouldUseAVAudioRecorder(for: AppState.shared.inputDeviceUID) {
            return startAVAudioRecorder(to: url)
        }

        do {
            let inputNode = engine.inputNode

            // Apply user-selected input device before asking the engine for formats.
            // Changing devices after a tap is installed can leave the tap with a stale
            // format and AVFAudio raises an Objective-C exception on the next start.
            setInputDevice(uid: AppState.shared.inputDeviceUID, on: engine)

            let recordingFormat = inputNode.outputFormat(forBus: 0)

            logInfo("AudioRecorder", "Input format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")

            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                logError("AudioRecorder", "Invalid input format — no audio input device?")
                return false
            }

            lock.lock()
            self.engine = engine
            self.audioFile = nil
            self.currentURL = url
            self.isCurrentlyRecording = true
            self.recordingStartedAt = Date()
            lock.unlock()

            // Let AVAudioEngine choose the tap format. The file is opened lazily from
            // the first real buffer, so file writing always matches the hardware.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.lock.lock()
                let recording = self.isCurrentlyRecording
                if recording, self.audioFile == nil {
                    do {
                        self.audioFile = try AVAudioFile(
                            forWriting: url,
                            settings: buffer.format.settings,
                            commonFormat: buffer.format.commonFormat,
                            interleaved: buffer.format.isInterleaved
                        )
                        logInfo("AudioRecorder", "Actual recording format: \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch")
                    } catch {
                        logError("AudioRecorder", "Failed to create audio file: \(error)")
                    }
                }
                let file = self.audioFile
                self.lock.unlock()
                guard recording, let file = file else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    logError("AudioRecorder", "Write error: \(error)")
                }
                // RMS audio level for overlay visualisation
                if let handler = self.audioLevelHandler,
                   let channelData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frameCount { let s = channelData[0][i]; sum += s * s }
                    let rms = frameCount > 0 ? sqrt(sum / Float(frameCount)) : 0
                    handler(min(1.0, rms * 8.0))
                }
                // Forward buffer to SpeechStreamer for live preview
                self.audioBufferHandler?(buffer)
            }

            engine.prepare()
            try engine.start()

            logInfo("AudioRecorder", "Recording started successfully")
            return true

        } catch {
            logError("AudioRecorder", "Failed to start recording: \(error)")
            removeTapSafely(on: engine)
            if engine.isRunning { engine.stop() }
            engine.reset()
            lock.lock()
            isCurrentlyRecording = false
            recordingStartedAt = nil
            audioFile = nil
            currentURL = nil
            self.engine = nil
            lastStoppedAt = Date()
            lock.unlock()
            return false
        }
    }

    private func startAVAudioRecorder(to url: URL) -> Bool {
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()

            lock.lock()
            self.recorder = recorder
            self.currentURL = url
            self.isCurrentlyRecording = true
            self.recordingStartedAt = Date()
            lock.unlock()

            guard recorder.record() else {
                logError("AudioRecorder", "AVAudioRecorder refused to start")
                lock.lock()
                self.recorder = nil
                self.currentURL = nil
                self.isCurrentlyRecording = false
                self.recordingStartedAt = nil
                self.lastStoppedAt = Date()
                lock.unlock()
                return false
            }

            startRecorderLevelTimer(recorder)
            logInfo("AudioRecorder", "Recording started successfully with AVAudioRecorder")
            return true
        } catch {
            logError("AudioRecorder", "Failed to start AVAudioRecorder: \(error)")
            lock.lock()
            self.recorder = nil
            self.currentURL = nil
            self.isCurrentlyRecording = false
            self.recordingStartedAt = nil
            self.lastStoppedAt = Date()
            lock.unlock()
            return false
        }
    }

    private func startRecorderLevelTimer(_ recorder: AVAudioRecorder) {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak recorder] _ in
            guard let self = self, let recorder = recorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let normalized = max(0, min(1, (power + 55) / 55))
            self.audioLevelHandler?(normalized)
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        lock.lock()
        guard isCurrentlyRecording else {
            logWarn("AudioRecorder", "stopRecording called but not recording")
            lock.unlock()
            completion(nil)
            return
        }

        isCurrentlyRecording = false
        recordingStartedAt = nil
        let url = currentURL
        let engine = self.engine
        let recorder = self.recorder
        audioFile = nil
        currentURL = nil
        self.engine = nil
        self.recorder = nil
        lastStoppedAt = Date()
        lock.unlock()

        logInfo("AudioRecorder", "Stopping recording")
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        if let engine {
            removeTapSafely(on: engine)
            if engine.isRunning { engine.stop() }
            engine.reset()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let url = url else {
                logError("AudioRecorder", "No URL after stop")
                completion(nil)
                return
            }

            let exists = FileManager.default.fileExists(atPath: url.path)
            var fileSize: UInt64 = 0
            if exists, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                fileSize = size
            }

            logInfo("AudioRecorder", "Audio file exists: \(exists), size: \(fileSize) bytes")

            if exists && fileSize > 100 {
                completion(url)
            } else {
                logError("AudioRecorder", "Audio file missing or empty")
                try? FileManager.default.removeItem(at: url)
                completion(nil)
            }
        }
    }

    private func removeTapSafely(on engine: AVAudioEngine?) {
        engine?.inputNode.removeTap(onBus: 0)
    }

    func forceReset() {
        logWarn("AudioRecorder", "Force reset")
        lock.lock()
        let engine = self.engine
        let recorder = self.recorder
        isCurrentlyRecording = false
        audioFile = nil
        currentURL = nil
        self.engine = nil
        self.recorder = nil
        lastStoppedAt = Date()
        lock.unlock()
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        removeTapSafely(on: engine)
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.reset()
        }
        logInfo("AudioRecorder", "Engine reset complete")
    }

    /// Returns all available audio input devices as (name, uid) pairs.
    /// uid is stable across reboots and safe to store in AppStorage.
    static func availableInputDevices() -> [(name: String, uid: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(1)  // kAudioObjectSystemObject (C macro, not bridged)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [(name: String, uid: String)] = []
        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else { continue }
            let bufPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(inputSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufPtr) == noErr else { continue }
            let bufList = bufPtr.assumingMemoryBound(to: AudioBufferList.self).pointee
            guard bufList.mNumberBuffers > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr else { continue }

            result.append((name: nameRef as String, uid: uidRef as String))
        }
        return result
    }

    private func shouldUseAVAudioRecorder(for uid: String) -> Bool {
        let targetUID = uid.isEmpty ? defaultInputDeviceUID() : uid
        guard let device = inputDeviceDetails(uid: targetUID) else { return false }
        let useAVAudioRecorder = AudioRecorderRouting.backend(for: device) == .avAudioRecorder
        if useAVAudioRecorder {
            logInfo("AudioRecorder", "Using AVAudioRecorder for Bluetooth input: \(device.name)")
        }
        return useAVAudioRecorder
    }

    private func inputDeviceDetails(uid: String?) -> AudioInputDeviceInfo? {
        guard let uid = uid, let deviceID = deviceID(for: uid) else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr else {
            return nil
        }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport)

        return AudioInputDeviceInfo(
            name: nameRef as String,
            uid: uid,
            transport: transportStatus == noErr ? transport : nil
        )
    }

    private func defaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(1)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceID) == noErr else {
            return nil
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr else {
            return nil
        }
        return uidRef as String
    }

    private func deviceID(for uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: CFString = uid as CFString
        var deviceID: AudioDeviceID = kAudioDeviceUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(1)
        let status = AudioObjectGetPropertyData(
            systemObject, &address,
            UInt32(MemoryLayout<CFString>.size), &uidRef,
            &dataSize, &deviceID
        )
        guard status == noErr, deviceID != kAudioDeviceUnknown else { return nil }
        return deviceID
    }

    /// Sets the engine's input device by UID. Call before engine.prepare()/start().
    private func setInputDevice(uid: String, on engine: AVAudioEngine) {
        guard !uid.isEmpty else { return }
        if uid == defaultInputDeviceUID() {
            logInfo("AudioRecorder", "Selected input is already the system default; leaving AVAudioEngine on default input")
            return
        }

        guard let deviceID = deviceID(for: uid) else {
            logWarn("AudioRecorder", "Could not find device for UID: \(uid)")
            return
        }
        // Set on the engine's input node AudioUnit
        guard let inputUnit = engine.inputNode.audioUnit else {
            logWarn("AudioRecorder", "No audioUnit on inputNode")
            return
        }
        var id = deviceID
        let setStatus = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if setStatus == noErr {
            logInfo("AudioRecorder", "Input device set to UID: \(uid)")
        } else {
            logWarn("AudioRecorder", "Failed to set input device (status: \(setStatus))")
        }
    }
}

extension Notification.Name {
    static let audioDeviceLost = Notification.Name("TypelessMLX.audioDeviceLost")
}

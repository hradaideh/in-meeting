import AVFoundation
import Foundation

/// Observe-only mic input peak → smoothed 0…1 on the main queue.
/// ponytail: if another app hogs the input device, start() may fail — overlay keeps
/// orange/green + static stub with level stuck at 0; no expand until the tap works.
final class MicLevelMonitor {
    static let shared = MicLevelMonitor()

    private(set) var level: Float = 0
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var running = false
    private var rawPeak: Float = 0
    private var displayTimer: Timer?
    private let noiseFloor: Float = 0.03
    private let attack: Float = 0.45
    private let release: Float = 0.12

    private init() {}

    func requestPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }

    func setActive(_ active: Bool) {
        if active {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !running else { return }
        requestPermissionIfNeeded { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    print("mic-level: microphone permission denied — stub only")
                    return
                }
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            print("mic-level: invalid input format — tap skipped")
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            var peak: Float = 0
            for ch in 0..<channels {
                let samples = channelData[ch]
                for i in 0..<frames {
                    peak = max(peak, abs(samples[i]))
                }
            }
            self.rawPeak = peak
        }

        do {
            try engine.start()
            running = true
            rawPeak = 0
            level = 0
            displayTimer?.invalidate()
            displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tickSmooth()
            }
            if let displayTimer {
                RunLoop.main.add(displayTimer, forMode: .common)
            }
            print("mic-level: tap started")
        } catch {
            input.removeTap(onBus: 0)
            print("mic-level: engine start failed (\(error)) — stub only")
            running = false
        }
    }

    private func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
            print("mic-level: tap stopped")
        }
        rawPeak = 0
        level = 0
        onLevel?(0)
    }

    private func tickSmooth() {
        let gated = max(0, rawPeak - noiseFloor) / max(0.0001, 1 - noiseFloor)
        let target = min(1, gated)
        let coeff = target > level ? attack : release
        level = level + (target - level) * coeff
        if level < 0.002 { level = 0 }
        onLevel?(level)
    }
}

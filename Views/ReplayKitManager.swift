//
//  ReplayKitManager.swift
//  Swingline
//
//  Screen recording of the analysis screen through ReplayKit, saved to the photo
//  library. The web overflow menu lists "Record this screen" as "Coming with the
//  native app". This is that.
//
//  WHY REPLAYKIT AND NOT A CUSTOM PIXEL GRAB
//
//  The analysis screen is a live SceneKit view, an AVPlayer, two Canvas overlays
//  and a PencilKit layer, all compositing every frame. Snapshotting that stack
//  with a custom renderer would mean pulling pixels out of a Metal backed SCNView
//  and a video layer and combining them by hand, which is a large amount of code
//  that fights the compositor. ReplayKit records exactly what the compositor
//  already produced, the whole screen, correctly, with the audio, for free. It is
//  the right tool and it is what the web build promised.
//
//  THE STOP MODEL THIS IMPLEMENTS
//
//  You asked for: start on the menu item, stop when the golfer taps the red
//  status bar timer. That red timer is the system recording indicator, and
//  tapping it is a system gesture that ends the ReplayKit capture. The app does
//  not, and cannot, intercept that tap. What the app CAN do is register for the
//  stop through RPScreenRecorder's own callback path, which fires whether the
//  golfer stops from the app's own stop button or from the system indicator.
//
//  So both routes are wired. There is an in app stop, and the system stop is
//  observed. When either fires, the finished recording is handed to the photo
//  library. This is the honest shape: the red timer genuinely does stop the
//  recording, and the save still happens, because the save is driven off the
//  recording ending rather than off which control ended it.
//
//  A HARD CONSTRAINT WORTH STATING
//
//  ReplayKit does not work in the simulator. It returns a recording unavailable
//  error immediately. This must be tested on a device, and the code surfaces that
//  error plainly rather than appearing to do nothing.
//
//  PERMISSIONS
//
//  ReplayKit shows its own consent alert on first record, so no usage string is
//  needed to start. Saving to the library needs NSPhotoLibraryAddUsageDescription
//  in the target's Info settings, or the save silently fails. See the notes with
//  this batch.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import ReplayKit
import Photos
import AVFoundation

@MainActor
@Observable
final class ReplayKitManager: NSObject {

    enum State: Equatable {
        case idle
        case starting
        case recording
        case saving
        case unavailable(String)
    }

    private(set) var state: State = .idle

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private let recorder = RPScreenRecorder.shared()

    // A message the host can surface as a toast. Set on every terminal outcome.
    var lastMessage: String?

    override init() {
        super.init()
        recorder.delegate = self
    }

    // MARK: Start

    /*
      Begin recording the whole screen.

      startCapture streams sample buffers to a handler, which is more control than
      this needs, so startRecording is used instead: it lets ReplayKit manage the
      buffer to its own file and hand back a preview when stopped. The microphone
      is enabled so a spoken coaching note is captured with the picture, which is
      the point of recording an analysis in the first place.
    */
    func start() {
        guard recorder.isAvailable else {
            let message = "Screen recording is not available. It does not run in the simulator, and can be disabled in Screen Time restrictions."
            state = .unavailable(message)
            lastMessage = message
            return
        }
        guard !isRecording else { return }

        state = .starting
        recorder.isMicrophoneEnabled = true

        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    let message = "Could not start recording. \(error.localizedDescription)"
                    self.state = .unavailable(message)
                    self.lastMessage = message
                    return
                }
                self.state = .recording
                self.lastMessage = "Recording. Tap the red status bar time to stop, or use Stop recording."
            }
        }
    }

    // MARK: Stop

    /*
      Stop and save.

      There is one stop route, stopToURL, deliberately. An earlier draft also had
      a stopRecording(handler:) path that hands back RPPreviewViewController, the
      system trim and share sheet. That was cut: the golfer's intent from a menu
      item that saves to Photos is to have the file, not to be handed an editor.
      stopRecording(withOutput:) writes the finished movie straight to a URL the
      app owns, which is exactly what is needed.

      The system red status bar timer is the other way a recording ends. That
      routes through screenRecorderDidChangeAvailability below, which calls this
      same method, so a recording ended from the system indicator still saves.
      Both routes end here, so the outcome never depends on which control stopped
      it.
    */
    func stopToURL() {
        guard isRecording else { return }
        state = .saving

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("swingline-screen-\(UUID().uuidString).mov")

        recorder.stopRecording(withOutput: output) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    let message = "Could not save the recording. \(error.localizedDescription)"
                    self.state = .idle
                    self.lastMessage = message
                    return
                }
                self.saveToPhotos(output)
            }
        }
    }

    // MARK: Save

    /*
      Copy the finished recording into the photo library.

      Authorisation is requested for addOnly, the narrowest scope, because the app
      only needs to add its own clip and never to read the library. A denied
      permission is reported rather than swallowed, so a golfer who said no once
      and forgot is told why nothing was saved.
    */
    private func saveToPhotos(_ url: URL) {
        state = .saving

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized, .limited:
                    self.performSave(url)
                default:
                    self.state = .idle
                    self.lastMessage = "Saved nowhere: permission to add to Photos was declined. Turn it on in Settings to keep screen recordings."
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func performSave(_ url: URL) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        } completionHandler: { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                self.state = .idle
                if success {
                    self.lastMessage = "Screen recording saved to Photos."
                } else {
                    let detail = error?.localizedDescription ?? "unknown error"
                    self.lastMessage = "Could not save to Photos. \(detail)"
                }
                /* The temporary file is copied into the library, so the working
                   copy is removed either way. */
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - Delegate

extension ReplayKitManager: RPScreenRecorderDelegate {

    /*
      Fired when recording becomes unavailable, which includes the golfer ending
      the capture from the system red timer. When that happens mid recording, the
      app follows up by stopping to a URL so the clip is still saved, matching the
      requested behaviour that tapping the red timer ends the recording and keeps
      the result.
    */
    nonisolated func screenRecorderDidChangeAvailability(_ recorder: RPScreenRecorder) {
        Task { @MainActor in
            if !recorder.isAvailable, self.isRecording {
                self.stopToURL()
            }
        }
    }

    nonisolated func screenRecorder(
        _ recorder: RPScreenRecorder,
        didStopRecordingWith previewViewController: RPPreviewViewController?,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.state = .idle
                self.lastMessage = "Recording ended. \(error.localizedDescription)"
            }
        }
    }
}

import SwiftUI
import AVFoundation

/*
  The camera preview layer and the small debug view that proves the pipeline
  works.

  The capture engine itself, CaptureViewModel, now lives in its own file,
  CaptureViewModel.swift. It was moved out of here so it can be its own unit
  without this file redeclaring it. Everything below still refers to it, and
  since both files are in the same module nothing else changes.

  The CaptureView at the bottom is a bare debug harness that shows the raw
  detector output with none of the design on top, kept because it is the
  fastest way to tell whether the camera and the pose provider are talking
  without the rest of the UI in the way.

  House rule: no em dashes anywhere.
*/

// MARK: - Preview layer

// A thin UIViewRepresentable so the live camera feed can sit behind the capture
// chrome. RecordView puts this at the back of its ZStack.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// MARK: - Debug view

// The bare harness. No design, just the raw detector output, for confirming the
// camera and provider are connected without the rest of the UI in the way. Now
// also shows the live swing phase and the running swing count.
struct CaptureView: View {
    @StateObject private var viewModel = CaptureViewModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: viewModel.session).ignoresSafeArea()

            VStack(spacing: 8) {
                Text("People detected: \(viewModel.latestPersonCount)")
                Text("Confidence: \(viewModel.latestConfidence, specifier: "%.2f")")
                Text("Tracked fps: \(viewModel.trackedFps)")
                Text("Hand speed: \(viewModel.handSpeed, specifier: "%.2f") m/s")
                Text("Swing phase: \(String(describing: viewModel.swingPhase))")
                Text("Swings this session: \(viewModel.swingCount)")
                Text("Buffered frames: \(viewModel.bufferedFrames)")
                if viewModel.permission == .denied {
                    Text("Camera permission denied")
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(.white)
            .padding()
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 40)
        }
        .onAppear { viewModel.requestPermissionAndStart() }
        .onDisappear { viewModel.stop() }
    }
}

#Preview {
    CaptureView()
}

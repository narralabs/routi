#if os(iOS)
import SwiftUI
import AVFoundation
import VisionKit

struct PhonePairingScanner: View {
    @Environment(\.dismiss) private var dismiss
    @State private var invitation: RelayInvitation?
    @State private var cameraReady = false
    @State private var cameraError: String?
    @State private var codeError: String?
    @State private var scanID = UUID()

    var body: some View {
        if let invitation {
            PhonePairingSheet(invitation: invitation)
        } else {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("On your Mac, open Settings → Routi Core → Routi Connect and choose Pair iPhone.")
                        .font(.callout).multilineTextAlignment(.center).padding(.horizontal)
                    if let cameraError {
                        ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text(cameraError))
                    } else if cameraReady {
                        PairingCamera { value in
                            do {
                                guard let url = URL(string: value) else { throw PairingError("This is not a Routi pairing code.") }
                                invitation = try RelayInvitation.parse(url)
                            } catch { codeError = error.localizedDescription }
                        } failed: { cameraError = $0 }
                        .id(scanID)
                    } else {
                        ProgressView().frame(maxHeight: .infinity)
                    }
                }
                .navigationTitle("Scan pairing code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .alert("Cannot use this code", isPresented: Binding(get: { codeError != nil }, set: { if !$0 { codeError = nil } })) {
                    Button("Scan again") { codeError = nil; scanID = UUID() }
                } message: { Text(codeError ?? "") }
                .task {
                    guard DataScannerViewController.isSupported else {
                        cameraError = "Use the iPhone Camera app to scan the code instead."
                        return
                    }
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    guard !Task.isCancelled else { return }
                    if allowed && DataScannerViewController.isAvailable {
                        cameraReady = true
                    } else {
                        cameraError = "Allow camera access for Routi Bot in iPhone Settings, or scan with the Camera app."
                    }
                }
            }
        }
    }
}

private struct PairingCamera: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let failed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        context.coordinator.start = Task { @MainActor in
            guard !Task.isCancelled else { return }
            do { try controller.startScanning() }
            catch { failed("The camera could not start. Close the scanner and try again.") }
        }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.start?.cancel()
        controller.stopScanning()
        controller.delegate = nil
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        let failed: (String) -> Void
        var start: Task<Void, Never>?
        private var delivered = false

        init(scanned: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
            self.scanned = scanned
            self.failed = failed
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let barcode) in addedItems {
                guard let value = barcode.payloadStringValue else { continue }
                delivered = true
                dataScanner.stopScanning()
                scanned(value)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            dataScanner.stopScanning()
            failed("The camera is unavailable. Close the scanner and try again.")
        }
    }
}
#endif

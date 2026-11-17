import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var store: WallStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = ScanController()
    @State private var name = ""
    @State private var askName = false
    @State private var savedID: UUID?
    var onSaved: (UUID) -> Void

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                Spacer()
                bottomPanel
            }
            .padding()

            if controller.isSaving {
                ProgressView("Saving wall…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear { controller.start() }
        .onDisappear { controller.pause() }
        .alert("Name this wall", isPresented: $askName) {
            TextField("e.g. Living room north", text: $name)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Note", isPresented: Binding(get: { controller.message != nil },
                                            set: { if !$0 { controller.message = nil } })) {
            Button("OK") {
                controller.message = nil
                finishIfSaved()
            }
        } message: {
            Text(controller.message ?? "")
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.trackingText)
                Text(controller.mappingStatus.userText)
                    .foregroundStyle(controller.mappingStatus.isGoodEnough ? .green : .orange)
                if !ARSupport.hasLiDAR {
                    Text("No LiDAR on this device – accuracy will be lower").foregroundStyle(.yellow)
                }
            }
            .font(.caption)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            Spacer()
            Toggle(isOn: $controller.showMesh) { Image(systemName: "cube.transparent") }
                .toggleStyle(.button)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var instruction: String {
        switch controller.step {
        case .tapFirstCorner:
            return "Walk around the room for a few seconds, then aim at the BOTTOM-LEFT corner of the wall (where it meets the floor) and tap."
        case .tapSecondCorner:
            return "Now tap the BOTTOM-RIGHT corner of the wall."
        case .adjust:
            return "Set the height so the blue frame covers the wall. Then press Record and sweep the phone slowly over the whole wall, about 1 m away, until coverage is near 100%. Or stand back and save a single shot."
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(instruction).font(.callout)
            if controller.step == .adjust {
                HStack {
                    Text(String(format: "Width %.2f m", controller.width))
                    Spacer()
                    Text(String(format: "Height %.2f m", controller.height))
                }
                .font(.caption.monospacedDigit())
                Slider(value: $controller.height, in: 0.5...5, step: 0.01)
                    .disabled(controller.isRecording)
                HStack(alignment: .center, spacing: 10) {
                    if let img = controller.mosaicPreview {
                        Image(uiImage: img).resizable().scaledToFit()
                            .frame(maxWidth: 110, maxHeight: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Video coverage %.0f%%", controller.coverage * 100))
                            .font(.caption.monospacedDigit().bold())
                        ProgressView(value: controller.coverage)
                        if let hint = controller.videoHint {
                            Text(hint).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                HStack {
                    Button("Start over") { controller.reset() }
                        .buttonStyle(.bordered)
                    Button {
                        controller.isRecording ? controller.stopVideo() : controller.startVideo()
                    } label: {
                        Label(controller.isRecording ? "Pause" : "Record", systemImage: controller.isRecording ? "pause.fill" : "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(controller.isRecording ? Color.red : nil)
                    Spacer()
                    Button {
                        askName = true
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isSaving)
                }
            } else if controller.step == .tapSecondCorner {
                Button("Start over") { controller.reset() }.buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func save() {
        controller.save(name: name, store: store) { id in
            guard let id else { return }
            savedID = id
            // If there is a note to show, wait until the user dismisses it.
            if controller.message == nil { finishIfSaved() }
        }
    }

    private func finishIfSaved() {
        guard let id = savedID else { return }
        savedID = nil
        dismiss()
        onSaved(id)
    }
}

struct Crosshair: View {
    var color: Color
    var body: some View {
        ZStack {
            Circle().stroke(color, lineWidth: 2).frame(width: 28, height: 28)
            Rectangle().fill(color).frame(width: 2, height: 14)
            Rectangle().fill(color).frame(width: 14, height: 2)
        }
        .shadow(radius: 2)
        .allowsHitTesting(false)
    }
}

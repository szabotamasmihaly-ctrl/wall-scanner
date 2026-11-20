import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var store: WallStore
    @EnvironmentObject private var buildings: BuildingStore
    @State private var choosingKnownPoint = false
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
        .overlay {
            if controller.linkedBuildingID != nil && controller.step == .adjust && controller.markTool == .off {
                Crosshair(color: .green)
            }
        }
        .sheet(isPresented: $choosingKnownPoint) {
            if let id = controller.linkedBuildingID {
                ControlPointPicker(buildingID: id) { cp in controller.markKnownPoint(cp) }
                    .environmentObject(buildings)
                    .presentationDetents([.medium, .large])
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mark in AR").font(.caption.bold())
                        Picker("Mark", selection: $controller.markTool) {
                            ForEach(ScanController.MarkTool.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if controller.markTool != .off {
                        HStack {
                            Picker("Type", selection: $controller.markKind) {
                                ForEach(FeatureKind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                            }
                            .pickerStyle(.menu)
                            Spacer()
                            Button("Undo") { controller.undoMark() }.font(.caption)
                            if controller.markTool == .run {
                                Button("Finish run") { controller.finishRun() }
                                    .font(.caption).disabled(controller.pendingRun.count < 2)
                            }
                        }
                        Text(controller.markTool == .spot ? "Tap a socket, box or hole on the wall." : "Tap points along the pipe, cable or bar, then Finish run.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !controller.features.isEmpty {
                        Text("\(controller.features.count) feature(s) marked").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !buildings.buildings.isEmpty {
                        HStack {
                            Picker("Building", selection: $controller.linkedBuildingID) {
                                Text("No building").tag(UUID?.none)
                                ForEach(buildings.buildings) { b in Text(b.name).tag(UUID?.some(b.id)) }
                            }
                            .pickerStyle(.menu)
                            Spacer()
                            if controller.linkedBuildingID != nil {
                                Button {
                                    choosingKnownPoint = true
                                } label: {
                                    Label("Known point (\(controller.observations.count))", systemImage: "scope")
                                }
                                .font(.caption)
                            }
                        }
                        if controller.linkedBuildingID != nil {
                            Text("Aim the green crosshair at 2 known points of the building (corners, survey marks, door frame) so this wall appears on the blueprint.")
                                .font(.caption2).foregroundStyle(.secondary)
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

import SwiftUI

struct OverlayView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: OverlayController

    init(wall: WallRecord, store: WallStore) {
        _controller = StateObject(wrappedValue: OverlayController(wall: wall, store: store))
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            if controller.isPlaced && controller.alignStep == .none {
                Crosshair(color: crosshairColor)
            }

            VStack(spacing: 10) {
                topBar
                if let r = controller.readout, controller.alignStep == .none {
                    readoutCard(r)
                }
                Spacer()
                bottomPanel
            }
            .padding()
        }
        .onAppear { controller.start() }
        .onDisappear { controller.pause() }
        .alert("Note", isPresented: Binding(get: { controller.message != nil },
                                            set: { if !$0 { controller.message = nil } })) {
            Button("OK") { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.wall.name).font(.caption.bold())
                Text(controller.trackingText).font(.caption)
                if !controller.isPlaced && controller.alignStep == .none {
                    Text("Searching for the saved wall… walk slowly and look around the room. If nothing appears after ~20 s, use Align manually.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
    }

    private var crosshairColor: Color {
        guard let r = controller.readout, r.onWall, let d = r.distance else { return .white }
        return Clearance(distance: d).color
    }

    private func readoutCard(_ r: OverlayController.Readout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "%.0f cm from left · %.0f cm above floor", r.x * 100, r.y * 100))
                .font(.callout.monospacedDigit())
            if !r.onWall {
                Text("Crosshair is outside the scanned area").font(.caption).foregroundStyle(.secondary)
            } else if let d = r.distance, let kind = r.nearestKind {
                let c = Clearance(distance: d)
                Label(String(format: "%@ · %.0f cm to nearest %@", c.label, d * 100, kind.label.lowercased()),
                      systemImage: c.symbol)
                    .font(.callout.bold())
                    .foregroundStyle(c.color)
            } else {
                Text("No features marked on this wall").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.alignStep {
            case .tapFirstCorner:
                Text("Manual alignment: tap the BOTTOM-LEFT corner of the wall (same corner you used when scanning).")
                    .font(.callout)
            case .tapSecondCorner:
                Text("Now tap the BOTTOM-RIGHT corner.").font(.callout)
            case .none:
                if controller.isPlaced {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                        Slider(value: $controller.opacity, in: 0...1)
                    }
                    HStack {
                        Toggle("Photo", isOn: $controller.options.showPhoto)
                        Toggle("Marks", isOn: $controller.options.showFeatures)
                        Toggle("Grid", isOn: $controller.options.showGrid)
                        Toggle("No-drill", isOn: $controller.options.showSafeZones)
                    }
                    .toggleStyle(.button)
                    .font(.caption)
                }
            }
            HStack {
                Button {
                    controller.beginManualAlign()
                } label: {
                    Label("Align manually", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                Spacer()
                if controller.placedManually {
                    Button {
                        controller.saveAlignment()
                    } label: {
                        Label("Remember this room", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Simple traffic-light rule for drilling near hidden features.
struct Clearance {
    let distance: Double
    var color: Color { distance < 0.05 ? .red : (distance < 0.15 ? .orange : .green) }
    var label: String { distance < 0.05 ? "Do not drill" : (distance < 0.15 ? "Caution" : "Clear") }
    var symbol: String { distance < 0.05 ? "xmark.octagon.fill" : (distance < 0.15 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") }
}

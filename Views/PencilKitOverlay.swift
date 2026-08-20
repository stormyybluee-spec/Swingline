//
//  PencilKitOverlay.swift
//  Swingline
//
//  A PencilKit drawing surface that sits over the analysis playback stack, plus
//  the toolbar that drives it. This is the manual telestration layer: automatic
//  tracking will sometimes fail, and when it does the answer is a pencil, not an
//  apology screen. A coach marking a swing plane by hand is the oldest tool in
//  video coaching and the one golfers reach for first.
//
//  WHAT THIS PORTS, AND WHERE IT DELIBERATELY DIVERGES
//
//  The web build's OverlayControls.jsx draws shape primitives: a line, an angle
//  and a circle, as SVG. This is not that. You asked for PencilKit, which is
//  freehand ink with a pen, an eraser, undo and redo, a clear, and a colour
//  choice. That is a richer manual tool than the web's three shapes, and it is
//  the native thing to build. The one convention carried across is the citrus
//  ink colour the web tool defaults to, so a mark drawn here reads the same as a
//  mark drawn there, and the "Done" affordance that closes the tool.
//
//  THE COORDINATE PROBLEM THIS SOLVES, AND THE ONE IT DOES NOT
//
//  A drawing is stored as PKDrawing data, which is ink in the canvas's own point
//  space. That space is the size of the video panel on the device it was drawn
//  on. Replayed on the same panel it lines up exactly. Replayed on a wildly
//  different panel size it would scale, because PencilKit ink is vector, not
//  pixel, so it stays crisp but its absolute position is panel relative. For an
//  annotation pinned to a specific spot on a specific swing that is acceptable,
//  and it is what every native drawing tool does. What it is NOT is frame
//  indexed: a mark drawn at the top of the backswing stays on screen for the
//  whole clip. That matches the web tool, which is also not frame indexed, and
//  it is the right call, because a coach's line is a note about the swing, not a
//  thing that happened at one instant of it.
//
//  PERSISTENCE
//
//  The canvas hands its PKDrawing out as Data through a binding the host owns.
//  The host attaches that Data to the SwingRecord and saves it, so the mark is
//  still there when the swing is reopened. Empty ink saves as nil, so a swing
//  the golfer never drew on does not carry an empty drawing blob forever.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI
import PencilKit

// MARK: - The canvas

/*
  A thin UIViewRepresentable around PKCanvasView.

  The tool (pen, eraser, colour, width) is pushed in from the host through the
  PencilKitController, rather than PencilKit's own floating PKToolPicker, for two
  reasons. First, the floating picker is enormous and is built for a full screen
  document editor, not a small video panel. Second, the app already has a design
  language, and a custom toolbar in that language reads as part of Swingline
  rather than as a system component bolted on.
*/
struct PencilCanvas: UIViewRepresentable {

    @Bindable var controller: PencilKitController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        /* Finger as well as pencil, because most golfers do not carry an Apple
           Pencil to the range. allowedTouchTypes defaults to pencil only on some
           configurations, so this is set explicitly. */
        canvas.drawingPolicy = .anyInput
        /* The canvas must not eat scroll or pinch when the tool is closed. The
           host toggles isUserInteractionEnabled through the controller. */
        canvas.isUserInteractionEnabled = controller.isActive
        canvas.delegate = context.coordinator

        /* Restore any previously saved ink. */
        if let drawing = controller.loadedDrawing {
            canvas.drawing = drawing
        }

        controller.attach(canvas)
        context.coordinator.applyTool()
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.isUserInteractionEnabled = controller.isActive
        context.coordinator.controller = controller
        context.coordinator.applyTool()
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var controller: PencilKitController

        init(controller: PencilKitController) {
            self.controller = controller
        }

        /* Every stroke change flows back to the controller so the host always
           has current ink to save, and so undo and redo enable correctly. */
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            controller.drawingChanged()
        }

        func applyTool() {
            controller.applyToolToCanvas()
        }
    }
}

// MARK: - The controller

/*
  Owns the tool state and the live canvas, and is the one object both the toolbar
  and the host talk to.

  It holds a weak reference to the PKCanvasView so it can push tool changes and
  pull drawing data without the view holding a strong reference back, which would
  outlive the panel. The undo manager is the canvas's own, reached through the
  view, so undo and redo are real PencilKit operations rather than a home rolled
  stack that could disagree with what the ink actually did.
*/
@MainActor
@Observable
final class PencilKitController {

    enum Tool: Equatable {
        case pen
        case eraser
    }

    // The palette offered in the toolbar. The first is the web tool's citrus, so
    // ink drawn on iOS matches ink drawn on the web build.
    static let palette: [Color] = [
        Color(red: 0.784, green: 1.0, blue: 0.302),   // citrus #c8ff4d
        Color(red: 1.0, green: 0.271, blue: 0.227),   // rust red #ff453a
        Color(red: 0.302, green: 0.651, blue: 1.0),   // blue #4da6ff
        Color(red: 0.941, green: 0.918, blue: 0.863),  // bone #f0eadc
    ]

    var isActive = false
    var tool: Tool = .pen
    var colour: Color = PencilKitController.palette[0]
    var width: CGFloat = 5

    // MARK: Shape tools (protractor and circle)

    enum ShapeMode: Equatable { case none, protractor, circle, line, text }
    // The active shape tool. When not none, taps and drags build shapes instead
    // of ink, and the ink canvas stops taking touches.
    var shapeMode: ShapeMode = .none

    /*
      Every finished shape stores the colour it was drawn in, so the colour row
      is universal: change the colour, and the next shape uses it, while shapes
      already on the canvas keep the colour they were made with. The colour is
      kept as red, green, blue, alpha components in the shape's own metadata,
      rather than a hex string or a new type, so DrawnShape stays a plain Codable
      value and no global Color extension is introduced that might clash with one
      the app already defines. Shapes saved before this existed carry no colour
      keys and fall back to citrus on render.
    */
    private func colourMetadata() -> [String: Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(colour).getRed(&r, green: &g, blue: &b, alpha: &a)
        return ["r": Double(r), "g": Double(g), "b": Double(b), "a": Double(a)]
    }

    // Line taps in progress: start, then end. Two taps make a line.
    var pendingLine: [CGPoint] = []

    // The text point tapped and waiting for the input sheet, normalised. Set by
    // a tap in text mode or by selecting the text tool, and read when the sheet
    // commits. The host opens the sheet through onRequestText.
    var pendingTextPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    // Text size, in the drawing surface's point space. Stored on each text shape
    // so it scales with the panel the same way ink and shapes do.
    var textSize: CGFloat = 28
    /*
      The host installs this so a tap in text mode, or a tap on the Text tool,
      can raise the SwiftUI text input sheet, which must live on a View. It is a
      plain closure rather than observed state, so assigning it never invalidates
      the view.
    */
    @ObservationIgnored var onRequestText: ((CGPoint) -> Void)?

    /*
      Finished shapes, stored with points normalised to 0...1 of the drawing
      surface, so they land in the right place after a rotation or on a different
      sized panel, the same reasoning as the landmarks.
    */
    var shapes: [DrawnShape] = []
    // Protractor taps in progress: vertex, then the two ray ends.
    var pendingProtractor: [CGPoint] = []

    func selectShape(_ mode: ShapeMode) {
        shapeMode = mode
        pendingProtractor = []
        pendingLine = []
    }

    // A protractor tap, in normalised coordinates. Three taps make an angle.
    func protractorTap(_ p: CGPoint) {
        pendingProtractor.append(p)
        if pendingProtractor.count == 3 {
            let v = pendingProtractor[0], a = pendingProtractor[1], b = pendingProtractor[2]
            var meta = colourMetadata()
            meta["angle"] = Self.angle(v, a, b)
            shapes.append(DrawnShape(type: .protractor, points: [v, a, b], metadata: meta))
            pendingProtractor = []
        }
    }

    // A finished circle drag, centre and a point on the rim, normalised.
    func commitCircle(centre: CGPoint, rim: CGPoint) {
        let r = Double(hypot(rim.x - centre.x, rim.y - centre.y))
        var meta = colourMetadata()
        meta["radius"] = r
        shapes.append(DrawnShape(type: .circle, points: [centre, rim], metadata: meta))
    }

    /*
      A line tap, in normalised coordinates. The first tap sets the start, the
      second sets the end and commits the line, then the pending state resets so
      the tool is ready for the next line. The line carries the current colour
      and the current width, captured now, so later colour or width changes do
      not reach back and alter it.
    */
    func lineTap(_ p: CGPoint) {
        pendingLine.append(p)
        if pendingLine.count == 2 {
            let a = pendingLine[0], b = pendingLine[1]
            var meta = colourMetadata()
            meta["width"] = Double(width)
            shapes.append(DrawnShape(type: .line, points: [a, b], metadata: meta))
            pendingLine = []
        }
    }

    /*
      Commit a text label at the pending point in the current colour and size.
      Empty or whitespace only text is ignored, so tapping Done on an empty field
      does not drop an invisible shape onto the canvas.
    */
    func commitText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var meta = colourMetadata()
        meta["size"] = Double(textSize)
        shapes.append(DrawnShape(type: .text, points: [pendingTextPoint], metadata: meta, text: text))
    }

    // Record where a text label should land and ask the host to raise the input
    // sheet. Used by both the Text tool button and a tap on the canvas.
    func requestText(at point: CGPoint) {
        pendingTextPoint = point
        onRequestText?(point)
    }

    // Undo the in progress protractor or line first, otherwise the last shape.
    func undoLastShape() {
        if !pendingProtractor.isEmpty { pendingProtractor = [] }
        else if !pendingLine.isEmpty { pendingLine = [] }
        else if !shapes.isEmpty { shapes.removeLast() }
    }

    func clearShapes() {
        shapes = []
        pendingProtractor = []
        pendingLine = []
    }

    var hasShapes: Bool { !shapes.isEmpty || !pendingProtractor.isEmpty || !pendingLine.isEmpty }

    static func angle(_ v: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let v1 = CGPoint(x: a.x - v.x, y: a.y - v.y)
        let v2 = CGPoint(x: b.x - v.x, y: b.y - v.y)
        let dot = Double(v1.x * v2.x + v1.y * v2.y)
        let cross = Double(v1.x * v2.y - v1.y * v2.x)
        return atan2(abs(cross), dot) * 180 / .pi
    }

    // Enable state for the toolbar buttons, kept in sync with the canvas.
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var hasInk = false

    // Ink restored from a saved record, applied when the canvas is created.
    var loadedDrawing: PKDrawing?

    private weak var canvas: PKCanvasView?

    // MARK: Canvas lifecycle

    func attach(_ canvas: PKCanvasView) {
        self.canvas = canvas
        refreshState()
    }

    func detach() {
        canvas = nil
    }

    // MARK: Tool

    func applyToolToCanvas() {
        guard let canvas else { return }
        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: UIColor(colour), width: width)
        case .eraser:
            /* Vector eraser removes whole strokes, which on a small panel is what
               a golfer expects: tap a stray line, it is gone, rather than nibbling
               a hole in it. */
            canvas.tool = PKEraserTool(.vector)
        }
    }

    func selectPen() {
        shapeMode = .none
        tool = .pen
        applyToolToCanvas()
    }

    func selectEraser() {
        shapeMode = .none
        tool = .eraser
        applyToolToCanvas()
    }

    func setColour(_ colour: Color) {
        self.colour = colour
        /*
          The colour row is universal. While a shape tool (protractor, circle,
          line, text) is up, changing the colour just changes the colour the next
          shape will use, and the active shape tool stays selected. Only in the
          ink modes does choosing a colour also switch back to the pen, so that
          picking a colour while the eraser is up does not silently do nothing.
        */
        if shapeMode == .none {
            tool = .pen
        }
        applyToolToCanvas()
    }

    // MARK: Edit operations

    func undo() {
        canvas?.undoManager?.undo()
        refreshState()
    }

    func redo() {
        canvas?.undoManager?.redo()
        refreshState()
    }

    func clear() {
        guard let canvas else { return }
        /* Registering the clear on the undo manager means an accidental clear is
           one undo away, rather than an irreversible wipe of a coach's markup. */
        let previous = canvas.drawing
        canvas.drawing = PKDrawing()
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in
            // A view's UndoManager fires its actions on the main thread, so the
            // isolation is real at runtime. assumeIsolated states that to the
            // compiler without deferring the undo a runloop turn, which a
            // Task { @MainActor } would do and which would make undo feel laggy.
            MainActor.assumeIsolated {
                target.drawing = previous
            }
        }
        refreshState()
    }

    func drawingChanged() {
        refreshState()
    }

    private func refreshState() {
        canUndo = canvas?.undoManager?.canUndo ?? false
        canRedo = canvas?.undoManager?.canRedo ?? false
        hasInk = !(canvas?.drawing.strokes.isEmpty ?? true)
    }

    // MARK: Persistence bridge

    /*
      Current annotation as Data, or nil when there is neither ink nor a shape.

      The format is a JSON bundle carrying the ink (PKDrawing data) and the
      shapes together, so both survive a reopen. Older records hold raw PKDrawing
      data instead, and load handles that.
    */
    func currentDrawingData() -> Data? {
        let inkData: Data? = {
            guard let canvas, !canvas.drawing.strokes.isEmpty else { return nil }
            return canvas.drawing.dataRepresentation()
        }()
        if inkData == nil && shapes.isEmpty { return nil }
        let bundle = AnnotationBundle(ink: inkData, shapes: shapes)
        return try? JSONEncoder().encode(bundle)
    }

    /*
      Load ink and shapes from stored Data before the canvas exists.

      New records are the JSON bundle. Older ones are raw PKDrawing data, which a
      failed bundle decode falls through to, so a swing annotated before shapes
      existed still shows its ink.
    */
    func load(from data: Data?) {
        guard let data else {
            loadedDrawing = nil
            shapes = []
            return
        }
        if let bundle = try? JSONDecoder().decode(AnnotationBundle.self, from: data) {
            shapes = bundle.shapes
            if let ink = bundle.ink, let drawing = try? PKDrawing(data: ink) {
                loadedDrawing = drawing
                if let canvas {
                    canvas.drawing = drawing
                    refreshState()
                }
            } else {
                loadedDrawing = nil
            }
            return
        }
        // Legacy raw PKDrawing.
        if let drawing = try? PKDrawing(data: data) {
            loadedDrawing = drawing
            shapes = []
            if let canvas {
                canvas.drawing = drawing
                refreshState()
            }
        } else {
            loadedDrawing = nil
            shapes = []
        }
    }
}

// MARK: - Shapes

/*
  A protractor angle or a circle, drawn over the ink. Points are normalised to
  0...1 of the drawing surface so they survive a resize. Metadata carries the
  derived value (the angle in degrees, or the radius as a fraction of the
  surface) so it does not have to be recomputed to display.
*/
struct DrawnShape: Codable, Identifiable {
    enum ShapeType: String, Codable { case protractor, circle, line, text }
    var id = UUID()
    let type: ShapeType
    let points: [CGPoint]
    let metadata: [String: Double]
    // The label for a text shape. Optional and defaulted so older bundles, which
    // never carried it, still decode.
    var text: String? = nil

    /*
      The colour the shape was drawn in, read back from the red, green, blue,
      alpha keys the controller writes into metadata at commit time. Shapes made
      before colours were stored have no such keys, so they fall back to citrus,
      which is the colour every shape used then anyway.
    */
    var colour: Color {
        guard let r = metadata["r"], let g = metadata["g"], let b = metadata["b"] else {
            return PencilKitController.palette[0]
        }
        return Color(red: r, green: g, blue: b).opacity(metadata["a"] ?? 1)
    }
}

// The stored annotation: ink plus shapes, encoded as JSON.
private struct AnnotationBundle: Codable {
    var ink: Data?
    var shapes: [DrawnShape]
}

// MARK: - The toolbar

/*
  The drawing toolbar, in the app's own language.

  Pen, eraser, a colour row, undo, redo, clear, and Done. Matches the intent of
  the web tool's bottom bar, expanded to the pen and eraser model PencilKit gives
  and this batch was asked for. Disabled buttons dim rather than vanish, so the
  bar does not reflow as ink is added and removed.
*/
struct PencilToolbar: View {
    @Bindable var controller: PencilKitController
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: Tok.s2) {
            HStack(spacing: Tok.s2) {
                toolButton(
                    system: "pencil.tip",
                    label: "Pen",
                    active: controller.tool == .pen
                ) { controller.selectPen() }

                toolButton(
                    system: "eraser",
                    label: "Eraser",
                    active: controller.tool == .eraser
                ) { controller.selectEraser() }

                toolButton(
                    system: "angle",
                    label: "Angle",
                    active: controller.shapeMode == .protractor
                ) { controller.selectShape(.protractor) }

                toolButton(
                    system: "circle.dashed",
                    label: "Circle",
                    active: controller.shapeMode == .circle
                ) { controller.selectShape(.circle) }

                Spacer(minLength: 0)

                iconButton(system: "arrow.uturn.backward", enabled: controller.canUndo || controller.hasShapes) {
                    // A shape tool undoes its shapes first, so the angle you just
                    // placed comes off before the ink underneath.
                    if controller.shapeMode != .none && controller.hasShapes {
                        controller.undoLastShape()
                    } else {
                        controller.undo()
                    }
                }
                iconButton(system: "arrow.uturn.forward", enabled: controller.canRedo) {
                    controller.redo()
                }
                iconButton(system: "trash", enabled: controller.hasInk || controller.hasShapes) {
                    controller.clear()
                    controller.clearShapes()
                }
            }

            HStack(spacing: Tok.s2) {
                ForEach(Array(PencilKitController.palette.enumerated()), id: \.offset) { _, colour in
                    colourDot(colour)
                }

                Spacer(minLength: 0)

                Button(action: onDone) {
                    Text("Done")
                        .font(.data(TypeScale.nano))
                        .foregroundStyle(Tok.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Tok.citrus))
                }
                .buttonStyle(PressScale())
            }
        }
        .padding(Tok.s3)
        .background {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .fill(Tok.turf800.opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tok.rMd, style: .continuous)
                .strokeBorder(Tok.line, lineWidth: 1)
        }
    }

    private func toolButton(system: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.data(TypeScale.nano))
            }
            .foregroundStyle(active ? Tok.ink : Tok.bone2)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(active ? Tok.citrus : Tok.turf700))
            .overlay(Capsule().strokeBorder(active ? .clear : Tok.line, lineWidth: 1))
        }
        .buttonStyle(PressScale())
    }

    private func iconButton(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Tok.bone : Tok.bone3)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Tok.turf700))
                .overlay(Circle().strokeBorder(Tok.line, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
    }

    private func colourDot(_ colour: Color) -> some View {
        let selected = controller.tool == .pen && controller.colour == colour
        return Button {
            controller.setColour(colour)
        } label: {
            Circle()
                .fill(colour)
                .frame(width: 26, height: 26)
                .overlay {
                    Circle().strokeBorder(selected ? Tok.bone : Tok.line, lineWidth: selected ? 2 : 1)
                }
                .padding(2)
        }
        .buttonStyle(PressScale())
    }
}

// MARK: - Shape overlay

/*
  Captures taps and drags for the protractor and circle tools and renders the
  shapes above the ink.

  Only live when a shape tool is selected, and it and the ink canvas never take
  touches at the same time: the host gates the ink canvas off while a shape tool
  is up, and this off while the pen or eraser is up. Points are normalised on
  capture and denormalised on render, so a shape stays put across a resize.
*/
struct ShapeOverlay: View {
    @Bindable var controller: PencilKitController
    @GestureState private var drag: DragState? = nil

    struct DragState {
        var start: CGPoint
        var current: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                for shape in controller.shapes {
                    render(shape, in: ctx, size: size)
                }
                renderPendingProtractor(in: ctx, size: size)
                renderPendingLine(in: ctx, size: size, drag: drag)
                if controller.shapeMode == .circle, let d = drag {
                    renderCirclePreview(start: d.start, current: d.current, in: ctx)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($drag) { value, state, _ in
                        state = DragState(start: value.startLocation, current: value.location)
                    }
                    .onEnded { value in
                        let moved = hypot(value.translation.width, value.translation.height)
                        switch controller.shapeMode {
                        case .protractor:
                            // A near stationary touch is a tap, which places one
                            // of the three protractor points.
                            if moved < 12 {
                                controller.protractorTap(norm(value.location, size))
                            }
                        case .circle:
                            if moved >= 8 {
                                controller.commitCircle(
                                    centre: norm(value.startLocation, size),
                                    rim: norm(value.location, size)
                                )
                            }
                        case .line:
                            // Two taps make a line. A tap is a near stationary
                            // touch, the same test the protractor uses.
                            if moved < 12 {
                                controller.lineTap(norm(value.location, size))
                            }
                        case .text:
                            // A tap moves the insertion point to where the golfer
                            // tapped and raises the input sheet there.
                            if moved < 12 {
                                controller.requestText(at: norm(value.location, size))
                            }
                        case .none:
                            break
                        }
                    }
            )
        }
    }

    // MARK: Coordinate helpers

    private func norm(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x / max(size.width, 1), y: p.y / max(size.height, 1))
    }

    private func denorm(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    // MARK: Rendering

    // The colour used for the in progress preview of whichever tool is up. The
    // finished shapes carry their own colour, but the pending dots, rubber band
    // line and circle preview take the currently selected colour so the golfer
    // sees the shape in the colour it will land in.
    private var pendingStroke: Color { controller.colour }

    private func render(_ shape: DrawnShape, in ctx: GraphicsContext, size: CGSize) {
        let stroke = shape.colour
        switch shape.type {
        case .protractor:
            guard shape.points.count == 3 else { return }
            let v = denorm(shape.points[0], size)
            let a = denorm(shape.points[1], size)
            let b = denorm(shape.points[2], size)
            var rays = Path()
            rays.move(to: a)
            rays.addLine(to: v)
            rays.addLine(to: b)
            ctx.stroke(rays, with: .color(stroke), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            label("\(Int((shape.metadata["angle"] ?? 0).rounded()))\u{00b0}", at: v, colour: stroke, in: ctx)
        case .circle:
            guard shape.points.count == 2 else { return }
            let c = denorm(shape.points[0], size)
            let rim = denorm(shape.points[1], size)
            let r = hypot(rim.x - c.x, rim.y - c.y)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(stroke), style: StrokeStyle(lineWidth: 2))
            label("R \(Int(r))", at: CGPoint(x: c.x, y: c.y - r - 12), colour: stroke, in: ctx)
        case .line:
            guard shape.points.count == 2 else { return }
            let a = denorm(shape.points[0], size)
            let b = denorm(shape.points[1], size)
            let w = CGFloat(shape.metadata["width"] ?? 2)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            ctx.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: w, lineCap: .round))
        case .text:
            guard let point = shape.points.first, let string = shape.text else { return }
            let at = denorm(point, size)
            let fontSize = CGFloat(shape.metadata["size"] ?? 28)
            let resolved = ctx.resolve(
                Text(string)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(stroke)
            )
            // Anchored at the point the golfer tapped, drawn with the same
            // shadow the angle and radius labels use so it reads on the video.
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1))
                layer.draw(resolved, at: at, anchor: .center)
            }
        }
    }

    private func renderPendingProtractor(in ctx: GraphicsContext, size: CGSize) {
        let pts = controller.pendingProtractor.map { denorm($0, size) }
        guard !pts.isEmpty else { return }
        for p in pts {
            let dot = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
            ctx.fill(Path(ellipseIn: dot), with: .color(pendingStroke))
        }
        if pts.count >= 2 {
            var path = Path()
            path.move(to: pts[1])
            path.addLine(to: pts[0])
            if pts.count == 3 { path.addLine(to: pts[2]) }
            ctx.stroke(path, with: .color(pendingStroke.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    /*
      The line in progress. After the first tap a dot marks the start, and while
      the finger is down for the second tap a dashed rubber band follows it, so
      the golfer can see the line before committing it.
    */
    private func renderPendingLine(in ctx: GraphicsContext, size: CGSize, drag: DragState?) {
        guard controller.shapeMode == .line, let first = controller.pendingLine.first else { return }
        let start = denorm(first, size)
        let dot = CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)
        ctx.fill(Path(ellipseIn: dot), with: .color(pendingStroke))
        if let d = drag {
            var path = Path()
            path.move(to: start)
            path.addLine(to: d.current)
            ctx.stroke(path, with: .color(pendingStroke.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    private func renderCirclePreview(start: CGPoint, current: CGPoint, in ctx: GraphicsContext) {
        let r = hypot(current.x - start.x, current.y - start.y)
        let rect = CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        ctx.stroke(Path(ellipseIn: rect), with: .color(pendingStroke.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }

    private func label(_ text: String, at point: CGPoint, colour: Color, in ctx: GraphicsContext) {
        let resolved = ctx.resolve(
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colour)
        )
        let at = CGPoint(x: point.x, y: point.y - 16)
        // A shadow via a layer filter, which reads on both light and dark
        // backgrounds without depending on a resolved text shadow property.
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1))
            layer.draw(resolved, at: at, anchor: .center)
        }
    }
}

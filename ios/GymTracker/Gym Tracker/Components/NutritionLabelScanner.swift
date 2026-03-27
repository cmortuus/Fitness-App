import SwiftUI
import AVFoundation
import Vision

/// Real-time OCR scanner that reads nutrition labels from live camera feed
struct NutritionLabelScanner: View {
    let barcode: String?
    let onResult: (ScannedNutrition) -> Void
    @Environment(\.dismiss) var dismiss

    @StateObject private var scanner = LiveOCRScanner()
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Live camera preview
                CameraPreviewView(session: scanner.session)
                    .ignoresSafeArea()

                // Recognized text overlay
                GeometryReader { geo in
                    ForEach(scanner.recognizedBoxes) { box in
                        let rect = box.rect.applying(
                            CGAffineTransform(scaleX: geo.size.width, y: geo.size.height)
                                .concatenating(CGAffineTransform(translationX: 0, y: 0))
                        )
                        // Flip Y — Vision uses bottom-left origin
                        let flipped = CGRect(
                            x: rect.origin.x,
                            y: geo.size.height - rect.origin.y - rect.height,
                            width: rect.width,
                            height: rect.height
                        )
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(box.isNutrition ? Color.green : Color.clear, lineWidth: 2)
                            .background(box.isNutrition ? Color.green.opacity(0.1) : Color.clear)
                            .frame(width: flipped.width, height: flipped.height)
                            .position(x: flipped.midX, y: flipped.midY)
                    }
                }
                .ignoresSafeArea()

                // Bottom info panel
                VStack {
                    Spacer()

                    VStack(spacing: 12) {
                        // Live extracted values
                        if scanner.parsed != nil {
                            HStack(spacing: 16) {
                                liveValue("Cal", scanner.parsed?.calories ?? 0, .orange)
                                liveValue("P", scanner.parsed?.protein ?? 0, .red)
                                liveValue("C", scanner.parsed?.carbs ?? 0, .blue)
                                liveValue("F", scanner.parsed?.fat ?? 0, .yellow)
                            }

                            Button {
                                showConfirm = true
                                scanner.pause()
                            } label: {
                                Label("Use These Values", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.green)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("Point at Nutrition Facts label")
                                    .font(.subheadline)
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .navigationTitle("Scan Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        scanner.stop()
                        dismiss()
                    }
                }
            }
            .onAppear { scanner.start() }
            .onDisappear { scanner.stop() }
            .sheet(isPresented: $showConfirm) {
                if let parsed = scanner.parsed {
                    ScannedConfirmView(nutrition: parsed, barcode: barcode) { confirmed in
                        onResult(confirmed)
                        dismiss()
                    }
                }
            }
        }
    }

    private func liveValue(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(value))")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live OCR Scanner

struct RecognizedBox: Identifiable {
    let id = UUID()
    let text: String
    let rect: CGRect
    let isNutrition: Bool
}

@MainActor
class LiveOCRScanner: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "ocr.scanner", qos: .userInitiated)
    private var isRunning = false
    private var frameCount = 0

    @Published var recognizedBoxes: [RecognizedBox] = []
    @Published var parsed: ScannedNutrition?

    // Nutrition-related keywords to match
    private let nutritionKeywords = [
        "calories", "cal", "kcal",
        "total fat", "fat",
        "saturated", "trans fat",
        "cholesterol",
        "sodium",
        "total carb", "carbohydrate",
        "dietary fiber", "fibre",
        "total sugars", "sugars", "added sugars",
        "protein",
        "vitamin", "calcium", "iron", "potassium",
        "serving size", "serv. size", "servings per",
        "amount per", "nutrition facts",
        "% daily value", "daily value"
    ]

    func start() {
        guard !isRunning else { return }
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func pause() {
        session.stopRunning()
    }

    func stop() {
        session.stopRunning()
        isRunning = false
    }

    // OCR processing moved inline to captureOutput delegate
}

extension LiveOCRScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Simple frame skip using static counter
        struct FrameCounter {
            nonisolated(unsafe) static var count = 0
        }
        FrameCounter.count += 1
        guard FrameCounter.count % 10 == 0 else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Process OCR on this background thread directly
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            var boxes: [RecognizedBox] = []
            var lines: [String] = []

            let keywords = [
                "calories", "cal", "kcal", "total fat", "fat", "saturated", "trans fat",
                "cholesterol", "sodium", "total carb", "carbohydrate", "dietary fiber",
                "fibre", "total sugars", "sugars", "added sugars", "protein",
                "vitamin", "calcium", "iron", "potassium", "serving size", "serv. size",
                "servings per", "amount per", "nutrition facts", "% daily value", "daily value"
            ]

            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string
                let lower = text.lowercased()
                let isNutrition = keywords.contains { lower.contains($0) }
                    || lower.range(of: #"\d+\s*(g|mg|mcg|cal|kcal|%)"#, options: .regularExpression) != nil

                boxes.append(RecognizedBox(text: text, rect: obs.boundingBox, isNutrition: isNutrition))
                lines.append(text)
            }

            let newParsed = parseNutritionLabel(lines)

            Task { @MainActor in
                self.recognizedBoxes = boxes
                if let newParsed, newParsed.calories > 0 {
                    self.parsed = newParsed
                }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}
}

class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Nutrition Label Parser

struct ScannedNutrition {
    var name: String = ""
    var servingSize: String = ""
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0
    var sugar: Double = 0
    var sodium: Double = 0
}

func parseNutritionLabel(_ lines: [String]) -> ScannedNutrition? {
    var result = ScannedNutrition()
    var foundAnything = false
    var nextLineIsCalories = false

    for line in lines {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)

        // Check if previous line was "Calories" header and this line is just a number
        if nextLineIsCalories {
            nextLineIsCalories = false
            if let num = extractNumber(from: line), num > 5 && num < 5000 {
                result.calories = num
                foundAnything = true
                continue
            }
        }

        // Calories — on same line as number
        if lower.contains("calories") && !lower.contains("from fat") && !lower.contains("% daily") {
            if let num = extractNumber(from: line.replacingOccurrences(of: "Calories", with: "", options: .caseInsensitive)), num > 5 && num < 5000 {
                result.calories = num
                foundAnything = true
            } else {
                // "Calories" alone — number is on the next line
                nextLineIsCalories = true
            }
        }

        // Total Fat
        if (lower.hasPrefix("total fat") || (lower.hasPrefix("fat") && !lower.contains("saturated") && !lower.contains("trans"))) {
            if let num = extractGrams(from: line) {
                result.fat = num
                foundAnything = true
            }
        }

        // Total Carbohydrate
        if lower.contains("total carb") || lower.hasPrefix("carbohydrate") {
            if let num = extractGrams(from: line) {
                result.carbs = num
                foundAnything = true
            }
        }

        // Protein
        if lower.hasPrefix("protein") {
            if let num = extractGrams(from: line) {
                result.protein = num
                foundAnything = true
            }
        }

        // Dietary Fiber
        if lower.contains("dietary fiber") || lower.contains("fibre") {
            if let num = extractGrams(from: line) {
                result.fiber = num
            }
        }

        // Sugars
        if lower.contains("total sugars") || (lower.hasPrefix("sugars") && !lower.contains("added")) {
            if let num = extractGrams(from: line) {
                result.sugar = num
            }
        }

        // Sodium
        if lower.hasPrefix("sodium") {
            if let num = extractNumber(from: line) {
                result.sodium = num
            }
        }

        // Serving size
        if lower.contains("serving size") || lower.contains("serv. size") {
            result.servingSize = line
                .replacingOccurrences(of: "Serving Size", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "Serv. Size", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    return foundAnything ? result : nil
}

private func extractNumber(from text: String) -> Double? {
    let pattern = #"(\d+\.?\d*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return Double(text[range])
}

private func extractGrams(from text: String) -> Double? {
    let pattern = #"(\d+\.?\d*)\s*g\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return Double(text[range])
}

// MARK: - Confirmation View

struct ScannedConfirmView: View {
    @State var nutrition: ScannedNutrition
    let barcode: String?
    let onConfirm: (ScannedNutrition) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Food Name") {
                    TextField("Name this food", text: $nutrition.name)
                }

                if !nutrition.servingSize.isEmpty {
                    Section("Serving Size") {
                        Text(nutrition.servingSize)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Macros (per serving)") {
                    macroRow("Calories", value: $nutrition.calories, unit: "cal")
                    macroRow("Protein", value: $nutrition.protein, unit: "g")
                    macroRow("Carbs", value: $nutrition.carbs, unit: "g")
                    macroRow("Fat", value: $nutrition.fat, unit: "g")
                }

                Section("Other") {
                    macroRow("Fiber", value: $nutrition.fiber, unit: "g")
                    macroRow("Sugar", value: $nutrition.sugar, unit: "g")
                    macroRow("Sodium", value: $nutrition.sodium, unit: "mg")
                }

                if let barcode {
                    Section {
                        Label("Barcode: \(barcode)", systemImage: "barcode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Saved for future scans")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Confirm Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onConfirm(nutrition)
                    }
                    .bold()
                    .disabled(nutrition.name.isEmpty)
                }
            }
        }
    }

    private func macroRow(_ label: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
        }
    }
}

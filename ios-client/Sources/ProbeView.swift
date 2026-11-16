import SwiftUI

/// Shows the decode probe (probe 1) for the bundled Mac and x265 samples. Results feed ADR-0007.
struct ProbeView: View {
    @State private var results: [DecodeProbe.Result] = []
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(running ? "Running…" : "Run decode probe") { run() }.disabled(running)
                } footer: {
                    Text("Decodes each bundled 1878×1334 HEVC sample with the hardware decoder required, and checks the output chroma. Send a screenshot of this screen back.")
                }
                ForEach(results) { r in
                    Section(r.file) {
                        LabeledContent("Result", value: r.passed ? "PASS" : "FAIL")
                        LabeledContent("SPS chroma_format_idc", value: r.spsChroma.map(String.init) ?? "?")
                        LabeledContent("Decoded", value: "\(r.decoded) / \(r.frames)")
                        LabeledContent("Output", value: r.outputFormat)
                        LabeledContent("Hardware", value: r.hardware.map { $0 ? "yes" : "no" } ?? "unknown")
                        LabeledContent("Decode ms p50 / max", value: "\(fmt(r.msP50)) / \(fmt(r.msMax))")
                        if let e = r.error { Text(e).font(.footnote).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Probes")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .font(.callout.monospacedDigit())
        }
    }

    private func run() {
        running = true
        Task.detached {
            let r = DecodeProbe.runAll()
            await MainActor.run { results = r; running = false }
        }
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
}

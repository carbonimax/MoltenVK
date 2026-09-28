// Copyright (c) 2026 Jean-Philippe Meunier
// SPDX-License-Identifier: Apache-2.0
// Runs the Vulkan trial once at launch, off the main thread, and offers the JSON report for export.
import SwiftUI

@main
struct PerVertexVulkanTrialApp: App {
    var body: some Scene {
        WindowGroup { TrialView() }
    }
}

struct TrialView: View {
    @State private var lines: [String] = []
    @State private var report: URL?
    @State private var running = false

    var body: some View {
        NavigationStack {
            List {
                Section("PerVertex Vulkan") {
                    Text(running ? "Essai en cours, un cas à la fois." : report == nil ? "Prêt." : "Essai terminé.")
                    if let report {
                        ShareLink("Exporter le rapport JSON", item: report)
                        Text(report.deletingLastPathComponent().lastPathComponent).font(.footnote.monospaced())
                    }
                    Button("Relancer l'essai") { start() }.disabled(running)
                }
                Section("Cas") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote.monospaced())
                    }
                }
            }
            .navigationTitle("PerVertex Vulkan")
        }
        .onAppear { if report == nil && !running { start() } }
    }

    private func start() {
        running = true
        lines = []
        DispatchQueue.global(qos: .userInitiated).async {
            let path = PVTrialRunner.runAll { line in
                DispatchQueue.main.async { lines.append(line) }
            }
            DispatchQueue.main.async {
                report = URL(fileURLWithPath: path)
                running = false
            }
        }
    }
}

import AppKit
import SwiftUI

enum JobState { case queued, running, done, failed, cancelled }

struct Job: Identifiable {
    let id = UUID()
    let title: String
    var state: JobState = .queued
    var message: String = ""
    var outputs: [URL] = []
}

@MainActor
final class JobManager: ObservableObject {
    static let shared = JobManager()

    @Published private(set) var jobs: [Job] = []
    private var pending: [(UUID, JobSpec)] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancelled: Set<UUID> = []
    private var running = 0

    func enqueue(_ specs: [JobSpec]) {
        guard !specs.isEmpty else { return }
        for s in specs {
            let j = Job(title: s.title)
            jobs.append(j)
            pending.append((j.id, s))
        }
        Windows.showJobs()
        pump()
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func pump() {
        while running < Prefs.maxJobs, !pending.isEmpty {
            let (id, spec) = pending.removeFirst()
            guard let i = index(id), jobs[i].state == .queued else { continue }
            running += 1
            jobs[i].state = .running
            tasks[id] = Task { [weak self] in
                var outputs: [URL] = []
                var failure: Error?
                do { outputs = try await spec.work() } catch { failure = error }
                self?.finish(id, outputs: outputs, error: failure)
            }
        }
    }

    private func finish(_ id: UUID, outputs: [URL], error: Error?) {
        running -= 1
        tasks[id] = nil
        if let i = index(id) {
            if cancelled.contains(id) {
                jobs[i].state = .cancelled
                jobs[i].message = "Cancelled"
            } else if let error {
                jobs[i].state = .failed
                jobs[i].message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            } else {
                jobs[i].state = .done
                jobs[i].outputs = outputs
                jobs[i].message = outputs.map { $0.lastPathComponent }.joined(separator: ", ")
            }
        }
        pump()
        scheduleAutoClose()
    }

    func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .queued:
            jobs[i].state = .cancelled
            jobs[i].message = "Cancelled"
            pending.removeAll { $0.0 == id }
        case .running:
            cancelled.insert(id)
            tasks[id]?.cancel()
        default: break
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    /// Closes the progress window a few seconds after everything succeeded.
    private func scheduleAutoClose() {
        guard running == 0, pending.isEmpty else { return }
        guard jobs.allSatisfy({ $0.state == .done || $0.state == .cancelled }) else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            if self.running == 0, self.pending.isEmpty,
               self.jobs.allSatisfy({ $0.state == .done || $0.state == .cancelled }) {
                Windows.hideJobs()
            }
        }
    }
}

struct JobsView: View {
    @ObservedObject var manager: JobManager

    var body: some View {
        VStack(spacing: 0) {
            if manager.jobs.isEmpty {
                Text("No jobs yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.jobs.reversed()) { job in
                    HStack(spacing: 10) {
                        icon(job.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).lineLimit(1).truncationMode(.middle)
                            if !job.message.isEmpty {
                                Text(job.message)
                                    .font(.caption)
                                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer()
                        if job.state == .queued || job.state == .running {
                            Button("Cancel") { manager.cancel(job.id) }
                        }
                        if job.state == .done, !job.outputs.isEmpty {
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                            if job.outputs.count == 1 {
                                Button("Open") { NSWorkspace.shared.open(job.outputs[0]) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear finished") { manager.clearFinished() }
            }
            .padding(8)
        }
        .frame(minWidth: 460, minHeight: 240)
    }

    @ViewBuilder
    private func icon(_ s: JobState) -> some View {
        switch s {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}

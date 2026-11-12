import Foundation

struct OwnershipAnswer: Sendable {
    let pid: pid_t
    let owns: Bool?
}

/// The cached UI is presented synchronously; AX work can never hold its show call.
@MainActor
func showThenReconcile(show: () -> Void,
                       candidates: () -> [pid_t],
                       sweep: @escaping @Sendable ([pid_t]) -> [OwnershipAnswer],
                       update: @escaping ([OwnershipAnswer]) async -> Void) -> Task<Void, Never> {
    show()
    let pids = candidates()
    let worker = Task.detached(priority: .utility) { sweep(pids) }
    return Task {
        await withTaskCancellationHandler {
            let answers = await worker.value
            guard !Task.isCancelled else { return }
            await update(answers)
        } onCancel: {
            worker.cancel()
        }
    }
}

@MainActor
func checkOwnershipSweep() async {
    let gate = DispatchSemaphore(value: 0)
    var visible = false
    var updated = false
    let task = showThenReconcile(show: { visible = true }, candidates: { [123] }, sweep: { pids in
        // Simulate a responder that cannot finish until the test releases it.
        gate.wait()
        return [OwnershipAnswer(pid: pids[0], owns: true)]
    }, update: { answers in
        check(visible && answers.first?.owns == true, "late ownership updates the shown panel")
        updated = true
    })
    check(visible && !updated, "show does not wait for AX")
    try? await Task.sleep(nanoseconds: 50_000_000)
    check(visible && !updated, "hung responder does not block the main actor")
    gate.signal()
    await task.value
    check(updated, "late result delivered")

    let cancelled = showThenReconcile(show: {}, candidates: { [] }, sweep: { _ in
        gate.wait()
        return []
    }, update: { _ in fail("cancelled result must not reopen a panel") })
    cancelled.cancel()
    gate.signal()
    await cancelled.value
    print("ownership sweep self-check OK")
}

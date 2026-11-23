import Observation

/// Runs `apply` now, and again after any observable value it read changes, for as long as `owner` lives.
/// AppKit has no binding to `@Observable`, so views are pushed their model's changes from here.
@MainActor
func keepCurrent<Owner: AnyObject & Sendable>(_ owner: Owner, _ apply: @escaping @MainActor (Owner) -> Void) {
  withObservationTracking {
    apply(owner)
  } onChange: { [weak owner] in
    // `onChange` runs before the value is set, so the next pass waits for the change to finish.
    Task { @MainActor in
      guard let owner else { return }

      keepCurrent(owner, apply)
    }
  }
}

import CoreMedia

/// Finishes and saves stopped recordings, showing progress while one is letterboxed and an
/// alert if something goes wrong. A save can outlive its window, so quitting waits for them here.
@MainActor
enum RecordingSaver {
  private static var saves: [UUID: Task<Void, Never>] = [:]

  static var isSaving: Bool { !saves.isEmpty }

  static func save(_ recording: Recording, endingAt endTime: CMTime) {
    let id = UUID()
    saves[id] = Task {
      await finish(recording, endingAt: endTime)
      saves[id] = nil
    }
  }

  static func waitUntilDone() async {
    while let save = saves.values.first {
      await save.value
    }
  }

  private static func finish(_ recording: Recording, endingAt endTime: CMTime) async {
    let prompt = RecordingSavePrompt()
    let saving = Task {
      try await recording.finish(at: endTime) { fraction in
        Task { @MainActor in prompt.update(fraction) }
      }
    }
    prompt.onSkip = { saving.cancel() }
    let result = await saving.result
    prompt.close()
    switch result {
    case .success(.saved(let url)):
      Log.app.info("Saved a recording to \(url.path(percentEncoded: false), privacy: .private)")
    case .success(.savedWithoutLetterboxing(let url, let error)):
      Log.app.info("Saved a recording to \(url.path(percentEncoded: false), privacy: .private)")
      Log.app.error("Couldn't letterbox the recording: \(error, privacy: .private)")
      Alert.show(
        title: "Couldn't Re-encode Recording",
        message: "It was saved as is, so rotated parts may look stretched in QuickTime Player.")
    case .failure(let error):
      Alert.show(error, title: "Couldn't Save Recording")
    }
  }
}

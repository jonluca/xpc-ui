import Foundation

// The privileged LaunchDaemon RPC surface is wired in the next checkpoint.
// Keeping a long-lived executable in the app bundle lets SMAppService expose
// registration status immediately while the native app remains useful without it.
RunLoop.current.run()

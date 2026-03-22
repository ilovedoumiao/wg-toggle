import Foundation

private struct HelperCommandResult {
	let exitCode: Int32
	let stdout: String
	let stderr: String
}

private final class WGToggleHelperService: NSObject, NSXPCListenerDelegate, WGToggleHelperProtocol {
	private let xpcListener = NSXPCListener(machServiceName: WGToggleHelperConstants.serviceName)

	func run() {
		xpcListener.delegate = self
		xpcListener.resume()
		RunLoop.current.run()
	}

	func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
		newConnection.exportedInterface = NSXPCInterface(with: WGToggleHelperProtocol.self)
		newConnection.exportedObject = self
		newConnection.resume()
		return true
	}

	func runCommand(_ command: String, profile: String?, withReply reply: @escaping (Int32, String, String) -> Void) {
		guard let requestedCommand = WGToggleHelperCommand(rawValue: command) else {
			reply(-1, "", "Unsupported command")
			return
		}

		let result = Self.execute(requestedCommand, profile: profile)
		reply(result.exitCode, result.stdout, result.stderr)
	}

	private static func execute(_ command: WGToggleHelperCommand, profile: String?) -> HelperCommandResult {
		switch command {
		case .up:
			guard let profile, isSafeProfileName(profile) else {
				return HelperCommandResult(exitCode: -1, stdout: "", stderr: "Missing WireGuard profile")
			}
			guard let wgQuickURL = resolveBinary(named: "wg-quick", fallback: "/opt/homebrew/bin/wg-quick") else {
				return HelperCommandResult(exitCode: -1, stdout: "", stderr: "wg-quick not found")
			}
			return runWGQuick(at: wgQuickURL, arguments: ["up", profile])
		case .down:
			guard let profile, isSafeProfileName(profile) else {
				return HelperCommandResult(exitCode: -1, stdout: "", stderr: "Missing WireGuard profile")
			}
			guard let wgQuickURL = resolveBinary(named: "wg-quick", fallback: "/opt/homebrew/bin/wg-quick") else {
				return HelperCommandResult(exitCode: -1, stdout: "", stderr: "wg-quick not found")
			}
			return runWGQuick(at: wgQuickURL, arguments: ["down", profile])
		case .show:
			guard let wgURL = resolveBinary(named: "wg", fallback: "/opt/homebrew/bin/wg") else {
				return HelperCommandResult(exitCode: -1, stdout: "", stderr: "wg not found")
			}
			return runProcess(at: wgURL, arguments: ["show"])
		}
	}

	private static func resolveBinary(named binaryName: String, fallback: String) -> URL? {
		let candidates = [
			fallback,
			"/usr/local/bin/\(binaryName)",
			"/usr/bin/\(binaryName)",
		]

		for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
			return URL(fileURLWithPath: candidate)
		}

		let whichResult = runProcess(at: URL(fileURLWithPath: "/usr/bin/which"), arguments: [binaryName])
		guard whichResult.exitCode == 0 else {
			return nil
		}

		guard let resolvedPath = whichResult.stdout
			.components(separatedBy: .newlines)
			.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		else {
			return nil
		}

		return URL(fileURLWithPath: resolvedPath)
	}

	private static func resolveBash() -> URL? {
		let candidates = [
			"/opt/homebrew/bin/bash",
			"/usr/local/bin/bash",
			"/bin/bash",
		]

		for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
			return URL(fileURLWithPath: candidate)
		}

		return nil
	}

	private static func runWGQuick(at executableURL: URL, arguments: [String]) -> HelperCommandResult {
		guard let bashURL = resolveBash() else {
			return HelperCommandResult(exitCode: -1, stdout: "", stderr: "bash not found")
		}

		return runProcess(at: bashURL, arguments: [executableURL.path] + arguments)
	}

	private static func isSafeProfileName(_ profile: String) -> Bool {
		let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
		return !profile.isEmpty && profile.rangeOfCharacter(from: allowedCharacters.inverted) == nil
	}

	private static func runProcess(at executableURL: URL, arguments: [String]) -> HelperCommandResult {
		let process = Process()
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()

		process.executableURL = executableURL
		process.arguments = arguments
		process.standardOutput = stdoutPipe
		process.standardError = stderrPipe

		do {
			try process.run()
			process.waitUntilExit()

			let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
			let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

			return HelperCommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
		} catch {
			return HelperCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
		}
	}
}

private let service = WGToggleHelperService()
service.run()

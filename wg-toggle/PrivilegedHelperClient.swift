import Foundation
import ServiceManagement

struct PrivilegedCommandResult {
	let exitCode: Int32
	let stdout: String
	let stderr: String
}

enum HelperPreparationResult {
	case ready
	case needsApproval
	case unavailable(String)
}

@MainActor
final class PrivilegedHelperClient {
	private let service = SMAppService.daemon(
		plistName: WGToggleHelperConstants.daemonPlistName
	)

	func prepare() -> HelperPreparationResult {
		switch service.status {
		case .enabled:
			return .ready
		case .notRegistered, .notFound:
			return registerService()
		case .requiresApproval:
			return .needsApproval
		@unknown default:
			return .unavailable("Unsupported helper status")
		}
	}

	func refreshRegistration() -> HelperPreparationResult {
		switch service.status {
		case .enabled:
			do {
				try service.unregister()
			} catch {
				return .unavailable(error.localizedDescription)
			}
		case .notRegistered, .notFound, .requiresApproval:
			break
		@unknown default:
			return .unavailable("Unsupported helper status")
		}

		return registerService()
	}

	func run(_ command: WGToggleHelperCommand, profile: String? = nil) async -> PrivilegedCommandResult {
		switch prepare() {
		case .ready:
			break
		case .needsApproval:
			return PrivilegedCommandResult(
				exitCode: -1,
				stdout: "",
				stderr: "Approve the background helper in System Settings > Login Items"
			)
		case .unavailable(let message):
			return PrivilegedCommandResult(
				exitCode: -1,
				stdout: "",
				stderr: message
			)
		}

		return await withCheckedContinuation { continuation in
			let connection = NSXPCConnection(
				machServiceName: WGToggleHelperConstants.serviceName,
				options: .privileged
			)
			connection.remoteObjectInterface = NSXPCInterface(
				with: WGToggleHelperProtocol.self
			)

			var didResume = false

			func finish(_ result: PrivilegedCommandResult) {
				guard !didResume else { return }
				didResume = true
				connection.invalidate()
				continuation.resume(returning: result)
			}

			connection.interruptionHandler = {
				finish(
					PrivilegedCommandResult(
						exitCode: -1,
						stdout: "",
						stderr: "Privileged helper connection interrupted"
					)
				)
			}

			connection.invalidationHandler = {
				finish(
					PrivilegedCommandResult(
						exitCode: -1,
						stdout: "",
						stderr: "Privileged helper connection closed"
					)
				)
			}

			connection.resume()

			guard
				let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
					finish(
						PrivilegedCommandResult(
							exitCode: -1,
							stdout: "",
							stderr: error.localizedDescription
						)
					)
				}) as? WGToggleHelperProtocol
			else {
				finish(
					PrivilegedCommandResult(
						exitCode: -1,
						stdout: "",
						stderr: "Unable to connect to privileged helper"
					)
				)
				return
			}

			proxy.runCommand(command.rawValue, profile: profile) { exitCode, stdout, stderr in
				finish(
					PrivilegedCommandResult(
						exitCode: exitCode,
						stdout: stdout,
						stderr: stderr
					)
				)
			}
		}
	}

	private func registerService() -> HelperPreparationResult {
		do {
			try service.register()
		} catch {
			return .unavailable("\(error.localizedDescription)\n\(bundleDiagnostics())")
		}

		switch service.status {
		case .enabled:
			return .ready
		case .requiresApproval:
			return .needsApproval
		case .notRegistered:
			return .unavailable("Privileged helper registration did not complete")
		case .notFound:
			return .unavailable(
				"Privileged helper registration not found. \(bundleDiagnostics())"
			)
		@unknown default:
			return .unavailable("Unsupported helper status")
		}
	}

	private func bundleDiagnostics() -> String {
		let bundleURL = Bundle.main.bundleURL
		let plistURL = bundleURL
			.appendingPathComponent("Contents/Library/LaunchDaemons")
			.appendingPathComponent(WGToggleHelperConstants.daemonPlistName)
		let helperURL = bundleURL
			.appendingPathComponent("Contents/MacOS")
			.appendingPathComponent(WGToggleHelperConstants.executableName)

		let plistExists = FileManager.default.fileExists(atPath: plistURL.path)
		let helperExists = FileManager.default.fileExists(atPath: helperURL.path)
		let plistState = plistExists ? "ok" : "missing"
		let helperState = helperExists ? "ok" : "missing"

		return "bundle=\(bundleURL.path), plist=\(plistState), helper=\(helperState)"
	}
}

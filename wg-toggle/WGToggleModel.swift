import Foundation
import Observation
import ServiceManagement

struct WireGuardProfile: Identifiable, Hashable {
	let name: String

	var id: String { name }
}

private struct CommandResult {
	let exitCode: Int32
	let stdout: String
	let stderr: String
}

private struct WireGuardSnapshot {
	let interfaceName: String
	let lastHandshake: String
	let transfer: String
	let persistentKeepalive: String
	let endpoint: String
	let allowedIPs: String
	let address: String
	let mtu: String
}

@MainActor
@Observable
final class WGToggleModel {
	private enum Constants {
		static let profileNameFallback = "No Profile"
		static let profileNameLimit = 18
		static let unknownValue = "Unknown"
		static let offDetails = ["Interface: Disconnected"]
		static let initialStatusRetryCount = 20
		static let initialStatusRetryDelay: UInt64 = 500_000_000
	}

	private enum ConnectionState {
		case on
		case off
		case transitioningUp
		case transitioningDown
		case error
	}

	private let helperClient = PrivilegedHelperClient()
	private var connectionState: ConnectionState = .off
	private var activeProfileName: String?
	private var activeInterfaceName: String?
	private var helperMessage: String?
	private var lastErrorMessage: String?
	private var hasOpenedMenu = false
	private var liveRefreshTask: Task<Void, Never>?
	private(set) var profiles: [WireGuardProfile] = []
	private(set) var selectedProfileName: String?
	private(set) var detailLines = Constants.offDetails
	private(set) var launchAtLoginEnabled = false
	private(set) var launchAtLoginBusy = false
	private(set) var isBusy = false

	init() {
		Task {
			_ = helperClient.refreshRegistration()
			await refreshProfiles()
			await resolveInitialConnectionState()
			await refreshLaunchAtLoginState()
		}
	}

	var selectedProfileDisplayName: String {
		let rawName = selectedProfileName ?? activeProfileName ?? Constants.profileNameFallback
		guard rawName.count > Constants.profileNameLimit else { return rawName }
		let cutoff = rawName.index(rawName.startIndex, offsetBy: Constants.profileNameLimit)
		return String(rawName[..<cutoff]) + "..."
	}

	var menuBarIconName: String {
		switch connectionState {
		case .on:
			return "circle.fill"
		case .off:
			return "circle"
		case .transitioningUp, .transitioningDown:
			return "circle.dotted"
		case .error:
			if hasOpenedMenu {
				return "exclamationmark.circle"
			}
			return "circle"
		}
	}

	var isRunningToggleOn: Bool {
		connectionState == .on
	}

	var isToggleEnabled: Bool {
		!isBusy && selectedProfileName != nil
	}

	var canSelectProfile: Bool {
		profiles.count > 1 && !isBusy
	}

	var versionText: String {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
		return "WG Toggler v\(version)"
	}

	var profileMenuTitle: String {
		guard let selectedProfileName else {
			return profiles.isEmpty ? "No Profiles Found" : "Select Profile"
		}

		return "Profile: \(selectedProfileName)"
	}

	func refreshOnMenuOpen() {
		Task {
			await refreshAll()
			try? await Task.sleep(nanoseconds: 400_000_000)
			await refreshConnectionState()
		}
	}

	func startLiveRefresh() {
		hasOpenedMenu = true
		refreshOnMenuOpen()
		guard liveRefreshTask == nil else { return }

		liveRefreshTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				guard !Task.isCancelled, let self else { break }
				await self.refreshAll()
			}
		}
	}

	func stopLiveRefresh() {
		liveRefreshTask?.cancel()
		liveRefreshTask = nil
	}

	func selectProfile(named profileName: String) {
		guard !isBusy else { return }
		guard selectedProfileName != profileName else { return }

		if connectionState == .on {
			let previousProfileName = activeProfileName ?? selectedProfileName
			selectedProfileName = profileName
			Task {
				await switchProfile(from: previousProfileName, to: profileName)
			}
			return
		}

		selectedProfileName = profileName
	}

	func setRunning(_ shouldRun: Bool) {
		guard !isBusy else { return }
		guard shouldRun != isRunningToggleOn else { return }

		Task {
			if shouldRun {
				await connect()
			} else {
				await disconnect()
			}
		}
	}

	func setLaunchAtLogin(_ enabled: Bool) {
		Task {
			await setLaunchAtLoginAsync(enabled)
		}
	}

	private func connect() async {
		guard let profileName = selectedProfileName else {
			applyError("No WireGuard profile found")
			return
		}

		await connect(to: profileName)
	}

	private func connect(to profileName: String) async {
		selectedProfileName = profileName
		activeProfileName = profileName

		isBusy = true
		connectionState = .transitioningUp
		setTransitionDetails(interface: "Connecting")

		let result = await helperClient.run(.up, profile: profileName)
		isBusy = false

		guard result.exitCode == 0 else {
			applyError(firstMeaningfulLine(in: result.stderr) ?? firstMeaningfulLine(in: result.stdout) ?? "Failed to start WireGuard")
			await refreshConnectionState(preserveFailureState: true)
			return
		}

		await waitForConnection(expectedOn: true)
	}

	private func disconnect() async {
		let profileCandidates = await disconnectProfileCandidates()
		guard profileCandidates.first != nil else {
			applyError("No active WireGuard profile to stop")
			return
		}

		await disconnect(using: profileCandidates)
	}

	private func disconnect(using profileCandidates: [String]) async {
		guard !profileCandidates.isEmpty else {
			applyError("No active WireGuard profile to stop")
			return
		}

		isBusy = true
		connectionState = .transitioningDown
		setTransitionDetails(interface: "Disconnected")

		var result = PrivilegedCommandResult(exitCode: -1, stdout: "", stderr: "No shutdown command attempted")

		for profileName in profileCandidates {
			result = await helperClient.run(.down, profile: profileName)
			if result.exitCode == 0 {
				break
			}
		}

		isBusy = false

		guard result.exitCode == 0 else {
			applyError(firstMeaningfulLine(in: result.stderr) ?? firstMeaningfulLine(in: result.stdout) ?? "Failed to stop WireGuard")
			await refreshConnectionState(preserveFailureState: true)
			return
		}

		await waitForConnection(expectedOn: false)
	}

	private func switchProfile(from previousProfileName: String?, to nextProfileName: String) async {
		let previousCandidates = await disconnectProfileCandidates(preferredProfile: previousProfileName)

		isBusy = true
		connectionState = .transitioningDown
		setTransitionDetails(interface: "Connecting")
		isBusy = false

		await disconnect(using: previousCandidates)

		guard connectionState == .off else {
			await syncSelectedProfileWithResolvedState(fallback: previousProfileName)
			return
		}

		await connect(to: nextProfileName)
		await syncSelectedProfileWithResolvedState(fallback: nextProfileName)
	}

	private func waitForConnection(expectedOn: Bool) async {
		for _ in 0..<12 {
			let result = await helperClient.run(.show)
			let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
			let isOn = !output.isEmpty

			if result.exitCode == 0 && isOn == expectedOn {
				await refreshConnectionState()
				return
			}

			try? await Task.sleep(nanoseconds: 500_000_000)
		}

		await refreshConnectionState()
	}

	private func refreshAll() async {
		await refreshProfiles()
		await refreshConnectionState()
		await refreshLaunchAtLoginState()
	}

	private func resolveInitialConnectionState() async {
		for attempt in 0..<Constants.initialStatusRetryCount {
			let result = await helperClient.run(.show)

			if result.exitCode == 0 {
				let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

				if output.isEmpty {
					activeProfileName = nil
					activeInterfaceName = nil
					helperMessage = nil
					lastErrorMessage = nil
					detailLines = Constants.offDetails
					connectionState = .off
					return
				}

				if let parsedStatus = await parseStatus(from: output) {
					helperMessage = nil
					lastErrorMessage = nil
					activeInterfaceName = parsedStatus.interfaceName
					if activeProfileName == nil {
						activeProfileName = selectedProfileName
					}
					if selectedProfileName == nil || !profiles.contains(where: { $0.name == selectedProfileName }) {
						selectedProfileName = activeProfileName
					}
					connectionState = .on
					detailLines = [
						"Interface: \(parsedStatus.interfaceName)",
						"Last Handshake: \(parsedStatus.lastHandshake)",
						"Transfer: \(parsedStatus.transfer)",
						"MTU: \(parsedStatus.mtu)",
						"Keep-Alive: \(parsedStatus.persistentKeepalive)",
						"Address: \(parsedStatus.address)",
						"Endpoint: \(parsedStatus.endpoint)",
						"Allowed IPs: \(parsedStatus.allowedIPs)",
					]
					return
				}

				helperMessage = nil
				lastErrorMessage = nil
				activeInterfaceName = parseValue(prefix: "interface:", in: output)
				connectionState = .on
				return
			}

			if attempt < Constants.initialStatusRetryCount - 1 {
				try? await Task.sleep(nanoseconds: Constants.initialStatusRetryDelay)
			}
		}

		activeProfileName = nil
		activeInterfaceName = nil
		connectionState = .off
	}

	private func refreshProfiles() async {
		let profileNames = await discoverProfiles()
		profiles = profileNames.map(WireGuardProfile.init(name:))

		if let selectedProfileName,
		   profileNames.contains(selectedProfileName)
		{
			return
		}

		if let activeProfileName,
		   profileNames.contains(activeProfileName)
		{
			selectedProfileName = activeProfileName
			return
		}

		selectedProfileName = profileNames.first
	}

	private func disconnectProfileCandidates(preferredProfile: String? = nil) async -> [String] {
		var candidates: [String] = []

		if let activeProfileName {
			candidates.append(activeProfileName)
		}

		if let preferredProfile {
			candidates.append(preferredProfile)
		}

		if let selectedProfileName {
			candidates.append(selectedProfileName)
		}

		var seen = Set<String>()
		return candidates.filter { seen.insert($0).inserted }
	}

	private func fetchLiveInterfaceName() async -> String? {
		let result = await helperClient.run(.show)
		guard result.exitCode == 0 else { return nil }
		let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !output.isEmpty else { return nil }
		return parseValue(prefix: "interface:", in: output)
	}

	private func syncSelectedProfileWithResolvedState(fallback: String? = nil) async {
		if let liveInterfaceName = await fetchLiveInterfaceName() {
			activeInterfaceName = liveInterfaceName
			if activeProfileName == nil {
				activeProfileName = selectedProfileName ?? fallback
			}
			if selectedProfileName == nil {
				selectedProfileName = activeProfileName ?? fallback
			}
			connectionState = .on
			return
		}

		activeProfileName = nil
		activeInterfaceName = nil
		connectionState = .off
		if let fallback {
			selectedProfileName = fallback
		}
	}

	private func refreshConnectionState(preserveFailureState: Bool = false) async {
		let result = await helperClient.run(.show)

		guard result.exitCode == 0 else {
			if !preserveFailureState {
				applyError(
					firstMeaningfulLine(in: result.stderr)
					?? firstMeaningfulLine(in: result.stdout)
					?? "Unable to query WireGuard status"
				)
			}
			connectionState = .error
			return
		}

		let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !output.isEmpty else {
			activeProfileName = nil
			activeInterfaceName = nil
			if !preserveFailureState {
				helperMessage = nil
				lastErrorMessage = nil
				detailLines = Constants.offDetails
			}
			connectionState = .off
			await refreshProfiles()
			return
		}

		guard let parsedStatus = await parseStatus(from: output) else {
			applyError("Unable to parse WireGuard status")
			connectionState = .error
			return
		}

		helperMessage = nil
		lastErrorMessage = nil
		activeInterfaceName = parsedStatus.interfaceName
		if activeProfileName == nil {
			activeProfileName = selectedProfileName
		}
		if selectedProfileName == nil || !profiles.contains(where: { $0.name == selectedProfileName }) {
			selectedProfileName = activeProfileName
		}
		connectionState = .on
		detailLines = [
			"Interface: \(parsedStatus.interfaceName)",
			"Last Handshake: \(parsedStatus.lastHandshake)",
			"Transfer: \(parsedStatus.transfer)",
			"MTU: \(parsedStatus.mtu)",
			"Keep-Alive: \(parsedStatus.persistentKeepalive)",
			"Address: \(parsedStatus.address)",
			"Endpoint: \(parsedStatus.endpoint)",
			"Allowed IPs: \(parsedStatus.allowedIPs)",
		]
		await refreshProfiles()
	}

	private func refreshLaunchAtLoginState() async {
		if #available(macOS 13.0, *) {
			switch SMAppService.mainApp.status {
			case .enabled:
				launchAtLoginEnabled = true
			case .notRegistered, .requiresApproval, .notFound:
				launchAtLoginEnabled = false
			@unknown default:
				launchAtLoginEnabled = false
			}
		} else {
			launchAtLoginEnabled = false
		}
	}

	private func setLaunchAtLoginAsync(_ enabled: Bool) async {
		guard #available(macOS 13.0, *) else { return }
		guard !launchAtLoginBusy else { return }

		launchAtLoginBusy = true
		defer { launchAtLoginBusy = false }

		do {
			if enabled {
				try SMAppService.mainApp.register()
			} else {
				try await SMAppService.mainApp.unregister()
			}

			launchAtLoginEnabled = enabled
		} catch {
			await refreshLaunchAtLoginState()
		}
	}

	private func discoverProfiles() async -> [String] {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let configURL = URL(fileURLWithPath: WGToggleHelperConstants.wireGuardConfigDirectory)
				let names: [String]

				do {
					let fileURLs = try FileManager.default.contentsOfDirectory(
						at: configURL,
						includingPropertiesForKeys: nil
					)
					names = fileURLs
						.filter { $0.pathExtension == "conf" }
						.map { $0.deletingPathExtension().lastPathComponent }
						.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
				} catch {
					names = []
				}

				continuation.resume(returning: names)
			}
		}
	}

	private func parseStatus(from output: String) async -> WireGuardSnapshot? {
		guard let interfaceName = parseValue(prefix: "interface:", in: output) else {
			return nil
		}

		async let interfaceDetails = fetchInterfaceDetails(for: interfaceName)
		async let configDetails = fetchConfigDetails(for: interfaceName)

		let handshake = parseValue(prefix: "latest handshake:", in: output) ?? "Never"
		let transfer = formatTransferDetails(
			parseValue(prefix: "transfer:", in: output) ?? Constants.unknownValue
		)
		let keepalive = parseValue(prefix: "persistent keepalive:", in: output) ?? "Off"
		let endpoint = parseValue(prefix: "endpoint:", in: output) ?? Constants.unknownValue
		let allowedIPs = parseValue(prefix: "allowed ips:", in: output) ?? Constants.unknownValue
		let details = await interfaceDetails
		let config = await configDetails

		return WireGuardSnapshot(
			interfaceName: interfaceName,
			lastHandshake: capitalizeFirstLetter(in: handshake),
			transfer: transfer,
			persistentKeepalive: capitalizeFirstLetter(in: keepalive),
			endpoint: endpoint,
			allowedIPs: allowedIPs,
			address: config.address ?? details.address ?? Constants.unknownValue,
			mtu: config.mtu ?? details.mtu ?? Constants.unknownValue
		)
	}

	private func fetchInterfaceDetails(for interfaceName: String) async -> (address: String?, mtu: String?) {
		let result = await runProcess(
			at: URL(fileURLWithPath: "/sbin/ifconfig"),
			arguments: [interfaceName]
		)

		guard result.exitCode == 0 else {
			return (nil, nil)
		}

		let lines = result.stdout.components(separatedBy: .newlines)
		let mtu = parseMTU(in: lines)
		let address = parseInterfaceAddress(in: lines)
		return (address, mtu)
	}

	private func fetchConfigDetails(for profileName: String) async -> (address: String?, mtu: String?) {
		let configPath = URL(fileURLWithPath: WGToggleHelperConstants.wireGuardConfigDirectory)
			.appendingPathComponent(profileName)
			.appendingPathExtension("conf")

		return await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				guard let contents = try? String(contentsOf: configPath, encoding: .utf8) else {
					continuation.resume(returning: (nil, nil))
					return
				}

				var inInterfaceSection = false
				var address: String?
				var mtu: String?

				for rawLine in contents.components(separatedBy: .newlines) {
					let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

					if trimmed.hasPrefix("[") {
						inInterfaceSection = trimmed.caseInsensitiveCompare("[Interface]") == .orderedSame
						continue
					}

					guard inInterfaceSection,
						  let separatorIndex = trimmed.firstIndex(of: "=")
					else {
						continue
					}

					let key = trimmed[..<separatorIndex]
						.trimmingCharacters(in: .whitespacesAndNewlines)
						.lowercased()
					let value = trimmed[trimmed.index(after: separatorIndex)...]
						.trimmingCharacters(in: .whitespacesAndNewlines)

					switch key {
					case "address":
						address = value.replacingOccurrences(of: ",", with: ", ")
					case "mtu":
						mtu = value
					default:
						break
					}
				}

				continuation.resume(returning: (address, mtu))
			}
		}
	}

	private func runProcess(at executableURL: URL, arguments: [String]) async -> CommandResult {
		await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
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

					let stdout = String(
						decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
						as: UTF8.self
					)
					let stderr = String(
						decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
						as: UTF8.self
					)

					continuation.resume(
						returning: CommandResult(
							exitCode: process.terminationStatus,
							stdout: stdout,
							stderr: stderr
						)
					)
				} catch {
					continuation.resume(
						returning: CommandResult(
							exitCode: -1,
							stdout: "",
							stderr: error.localizedDescription
						)
					)
				}
			}
		}
	}

	private func setTransitionDetails(interface: String) {
		detailLines = ["Interface: \(interface)"]
	}

	private func applyError(_ message: String) {
		helperMessage = message
		lastErrorMessage = message
		if helperMessage?.localizedCaseInsensitiveContains("wg-quick not found") == true {
			detailLines = ["wg-quick not found"]
		} else if helperMessage?.localizedCaseInsensitiveContains("approve the background helper") == true {
			detailLines = [
				"Interface: Approval Needed",
				"Last Handshake: -",
				"Transfer: -",
				"MTU: -",
				"Keep-Alive: -",
				"Address: -",
				"Endpoint: -",
				"Allowed IPs: -",
			]
		} else {
			detailLines = [
				"Interface: Error",
				"Last Handshake: -",
				"Transfer: -",
				"MTU: -",
				"Keep-Alive: -",
				"Address: -",
				"Endpoint: -",
				"Allowed IPs: \(message)",
			]
		}
	}

	private func parseValue(prefix: String, in output: String) -> String? {
		for rawLine in output.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
			guard line.lowercased().hasPrefix(prefix) else { continue }
			return line.dropFirst(prefix.count)
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		return nil
	}

	private func parseMTU(in lines: [String]) -> String? {
		guard let headerLine = lines.first else { return nil }
		let parts = headerLine.components(separatedBy: .whitespaces)
		guard let mtuIndex = parts.firstIndex(of: "mtu"), parts.indices.contains(mtuIndex + 1) else {
			return nil
		}
		return parts[mtuIndex + 1]
	}

	private func parseInterfaceAddress(in lines: [String]) -> String? {
		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			guard trimmed.hasPrefix("inet ") else { continue }
			let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
			guard components.count >= 2 else { continue }
			return components[1]
		}
		return nil
	}

	private func firstMeaningfulLine(in text: String) -> String? {
		text
			.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.first(where: { !$0.isEmpty })
	}

	private func formatTransferDetails(_ text: String) -> String {
		let parts = text.split(separator: ",", omittingEmptySubsequences: false)
		let formattedParts = parts.map { part in
			formatTransferComponent(part.trimmingCharacters(in: .whitespacesAndNewlines))
		}
		return formattedParts.joined(separator: ", ")
	}

	private func formatTransferComponent(_ component: String) -> String {
		let tokens = component.split(separator: " ")
		guard tokens.count >= 3, let value = Double(tokens[0]) else {
			return component
		}

		let byteCount: Double
		switch String(tokens[1]).lowercased() {
		case "b":
			byteCount = value
		case "kib":
			byteCount = value * 1_024
		case "mib":
			byteCount = value * 1_048_576
		case "gib":
			byteCount = value * 1_073_741_824
		case "tib":
			byteCount = value * 1_099_511_627_776
		case "kb":
			byteCount = value * 1_000
		case "mb":
			byteCount = value * 1_000_000
		case "gb":
			byteCount = value * 1_000_000_000
		case "tb":
			byteCount = value * 1_000_000_000_000
		default:
			return component
		}

		let rawDirection = tokens.dropFirst(2).joined(separator: " ")
		let direction: String
		switch rawDirection.lowercased() {
		case "received":
			direction = "down"
		case "sent":
			direction = "up"
		default:
			direction = rawDirection
		}

		return "\(decimalTransferString(bytes: byteCount)) \(direction)"
	}

	private func decimalTransferString(bytes: Double) -> String {
		let units = ["B", "KB", "MB", "GB", "TB"]
		var value = max(bytes, 0)
		var unitIndex = 0

		while value >= 1_000, unitIndex < units.count - 1 {
			value /= 1_000
			unitIndex += 1
		}

		let decimals: Int
		if unitIndex == 0 || value >= 100 {
			decimals = 0
		} else if value >= 10 {
			decimals = 1
		} else {
			decimals = 2
		}

		return String(format: "%.*f %@", decimals, value, units[unitIndex])
	}

	private func capitalizeFirstLetter(in text: String) -> String {
		guard let firstCharacter = text.first else { return text }
		return String(firstCharacter).uppercased() + text.dropFirst()
	}
}

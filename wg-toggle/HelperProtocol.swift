import Foundation

@objc protocol WGToggleHelperProtocol {
	func runCommand(
		_ command: String,
		profile: String?,
		withReply reply: @escaping (Int32, String, String) -> Void
	)
}

enum WGToggleHelperCommand: String {
	case up
	case down
	case show
}

enum WGToggleHelperConstants {
	static let serviceName = "com.doumiao.wg-toggle.helper"
	static let daemonPlistName = "com.doumiao.wg-toggle.helper.plist"
	static let executableName = "wg-toggle-helper"
	static let wireGuardConfigDirectory = "/opt/homebrew/etc/wireguard"
}

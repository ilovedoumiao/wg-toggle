import SwiftUI

@main
struct wg_toggleApp: App {
	@State private var model = WGToggleModel()
	@State private var isHoveringQuit = false

	var body: some Scene {
		MenuBarExtra {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text("WireGuard")
					Spacer(minLength: 16)
					Toggle(
						isOn: Binding(
							get: { model.isRunningToggleOn },
							set: { model.setRunning($0) }
						)
					) {
						EmptyView()
					}
					.toggleStyle(.switch)
					.controlSize(.small)
					.disabled(!model.isToggleEnabled)
				}
				.padding(.top, -3)

				Divider()

				Menu(model.profileMenuTitle) {
					ForEach(model.profiles) { profile in
						Button {
							model.selectProfile(named: profile.name)
						} label: {
							Text(profile.name)
						}
					}
					
					Divider()
					
					Text(model.profilesLocationText)
						.font(.system(size: 10))
						.opacity(0.5)

				}
				.disabled(!model.canSelectProfile)

				VStack(alignment: .leading, spacing: 2) {
					ForEach(model.detailLines, id: \.self) { line in
						Text(line)
					}
				}
				.font(.system(size: 12))
				.opacity(0.5)

				Divider()

				HStack {
					Text("Launch at login")
					Spacer(minLength: 16)
					Toggle(
						isOn: Binding(
							get: { model.launchAtLoginEnabled },
							set: { model.setLaunchAtLogin($0) }
						)
					) {
						EmptyView()
					}
					.toggleStyle(.switch)
					.controlSize(.small)
					.disabled(model.launchAtLoginBusy)
				}

				Divider()

				Text(model.versionText)
					.font(.system(size: 12))
					.opacity(0.5)
					.padding(.bottom, -3)

				Button {
					NSApplication.shared.terminate(nil)
				} label: {
					HStack {
						Text("Quit")
						Spacer(minLength: 16)
						Text("⌘Q")
							.opacity(0.5)
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.vertical, 4)
					.contentShape(Rectangle())
					.background {
						RoundedRectangle(cornerRadius: 5)
							.fill(Color.accentColor.opacity(isHoveringQuit ? 0.7 : 0))
							.padding(.horizontal, -6)
					}
				}
				.buttonStyle(.plain)
				.onHover { hovering in
					isHoveringQuit = hovering
				}
				.keyboardShortcut("q", modifiers: .command)
			}
			.padding(.horizontal, 12)
			.padding(.top, 12)
			.padding(.bottom, 6)
			.frame(width: 240, alignment: .leading)
			.onAppear {
				model.startLiveRefresh()
			}
			.onDisappear {
				model.stopLiveRefresh()
			}
		} label: {
			Image(model.menuBarIconName)
				.renderingMode(.template)
				.resizable()
				.scaledToFit()
				.frame(width: 18, height: 18, alignment: .center)
		}
		.menuBarExtraStyle(.window)
	}
}

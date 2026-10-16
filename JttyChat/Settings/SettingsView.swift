import SwiftUI

/// The Settings window, in three tabs: General (callsign and message
/// options), Audio (input/output device choice), and Transceiver for Hamlib
/// rig control (model, port, serial line
/// settings - baud rate, data/stop bits, parity, handshake, DTR/RTS - and
/// a Connect button that shows the rig's current frequency/mode). Ported
/// from JttyChatLinux/src/SettingsDialog.{h,cpp}.
///
/// Fields are edited in local @State ("draft") and only written back to
/// AppSettings (and persisted) when OK is pressed, matching the original
/// dialog's Cancel/OK semantics.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var callsign = ""
    @State private var capitalizeMessages = false
    @State private var appendCallsign = false

    @State private var inputDevices: [AudioDeviceInfo] = []
    @State private var outputDevices: [AudioDeviceInfo] = []
    @State private var selectedInputUID: String?
    @State private var selectedOutputUID: String?
    @State private var inputGainDb = 0.0
    @State private var outputGainDb = 0.0

    @State private var rigs: [RigInfo] = []
    @State private var isLoadingRigs = false
    @State private var selectedRigModel: Int?
    @State private var rigPort = ""
    @State private var discoveredPorts: [String] = []
    @State private var rigSerial = RigSerialConfig()
    // The selected model's own default for each serial setting, shown as
    // "Default (8)" etc.; empty until looked up, or for models without a
    // serial port.
    @State private var rigSerialDefaults: [RigSerialSetting: String] = [:]
    @State private var rigMode = RigController.defaultModeValue
    // The selected model's modes; empty until looked up.
    @State private var rigModes: [String] = []

    @State private var isConnecting = false
    @State private var rigStatusText = ""
    @State private var rigStatusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // All three tabs edit the same draft state, so OK/Cancel below
            // apply to (or discard) changes made on any of them.
            TabView {
                Tab("General", systemImage: "person") {
                    generalTab
                }
                Tab("Audio", systemImage: "speaker.wave.2") {
                    audioTab
                }
                Tab("Transceiver", systemImage: "antenna.radiowaves.left.and.right") {
                    transceiverTab
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loadState() }
        .onChange(of: inputGainDb) { _, gainDb in
            viewModel.previewInputGain(db: gainDb)
        }
        // Back to the saved gain: after OK that's the new one, after Cancel
        // (or closing the window) it drops the unsaved preview.
        .onDisappear {
            viewModel.previewInputGain(db: settings.audioInputGainDb)
            viewModel.stopTestTone()
        }
        .onChange(of: selectedRigModel) { _, model in
            loadSerialDefaults(model: model)
            loadModes(model: model)
        }
    }

    private var generalTab: some View {
        Form {
            TextField("Callsign:", text: $callsign, prompt: Text("e.g. W1AW"))
            Toggle("Capitalise messages", isOn: $capitalizeMessages)
            Toggle("Append callsign", isOn: $appendCallsign)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var audioTab: some View {
        Form {
            Picker("Audio Input:", selection: $selectedInputUID) {
                ForEach(inputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            LabeledContent("Input Level:") {
                LevelMeter(levels: viewModel.levels, level: \.inputDb, gainDb: inputGainDb)
            }
            gainSlider("Input Gain:", value: $inputGainDb, range: AudioGain.inputRangeDb)

            Spacer().frame(height: 12)

            Picker("Audio Output:", selection: $selectedOutputUID) {
                ForEach(outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            LabeledContent("Output Level:") {
                LevelMeter(levels: viewModel.levels, level: \.outputDb, gainDb: outputGainDb)
            }
            .help("Shows the level while transmitting")
            gainSlider("Output Gain:", value: $outputGainDb, range: AudioGain.outputRangeDb)
            LabeledContent("") {
                Button("Test") {}
                    .buttonStyle(HoldButtonStyle { isPressed in
                        if isPressed {
                            viewModel.startTestTone(outputDeviceUID: selectedOutputUID, gainDb: outputGainDb)
                        } else {
                            viewModel.stopTestTone()
                        }
                    })
                    .disabled(viewModel.isSending)
                    .help("Hold to play a 1 kHz tone through the audio output (doesn't key the rig)")
                    .accessibilityHint("Plays a 1 kilohertz tone while held down")
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func gainSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: 1)
                    .accessibilityLabel(label)
                    .accessibilityValue("\(Int(value.wrappedValue)) decibels")
                Text(value.wrappedValue > 0 ? "+\(Int(value.wrappedValue)) dB" : "\(Int(value.wrappedValue)) dB")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private var transceiverTab: some View {
        Form {
            Picker("Rig Model:", selection: $selectedRigModel) {
                Text(isLoadingRigs ? "Loading..." : "None").tag(Int?.none)
                ForEach(rigs) { rig in
                    Text(rig.label).tag(Optional(rig.model))
                }
            }

            Picker("Mode:", selection: $rigMode) {
                Text(defaultModeLabel).tag(RigController.defaultModeValue)
                ForEach(modeChoices, id: \.self) { mode in
                    Text(mode).tag(mode)
                }
            }
            .help("Set on the rig when connecting and when changing frequency")

            HStack(spacing: 4) {
                TextField("Rig Port:", text: $rigPort, prompt: Text("/dev/cu.usbserial-XXXX"))
                Menu {
                    ForEach(discoveredPorts, id: \.self) { port in
                        Button(port) { rigPort = port }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose a detected port")
            }

            ForEach(RigSerialSetting.allCases) { setting in
                Picker(setting.label, selection: $rigSerial[setting]) {
                    Text(defaultLabel(for: setting)).tag(RigSerialConfig.defaultValue)
                    ForEach(setting.options, id: \.self) { value in
                        Text(setting.displayName(for: value)).tag(value)
                    }
                }
            }

            LabeledContent("") {
                Button("Connect") { connectToRig() }
                    .disabled(isConnecting || selectedRigModel == nil)
            }

            if !rigStatusText.isEmpty {
                LabeledContent("") {
                    Text(rigStatusText)
                        .foregroundColor(rigStatusIsError ? .red : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent("Hamlib Version:") {
                Text(RigController.hamlibVersion)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Hamlib Library:") {
                Text(RigController.hamlibLibraryPath)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
    }

    // "Default (PKTUSB)", once the model's modes are known.
    private var defaultModeLabel: String {
        guard !rigModes.isEmpty else { return RigController.defaultModeValue }
        return "\(RigController.defaultModeValue) (\(RigController.defaultMode(among: rigModes)))"
    }

    // The model's modes, plus the saved one if the model doesn't list it
    // (e.g. before the list has loaded), so the popup can always show it.
    private var modeChoices: [String] {
        if rigMode == RigController.defaultModeValue || rigModes.contains(rigMode) {
            return rigModes
        }
        return rigModes + [rigMode]
    }

    private func loadModes(model: Int?) {
        rigModes = []
        guard let model else { return }
        Task.detached {
            let modes = RigController.supportedModes(model: model)
            await MainActor.run {
                // Ignore a lookup for a model that's since been changed.
                if self.selectedRigModel == model {
                    self.rigModes = modes
                }
            }
        }
    }

    private func defaultLabel(for setting: RigSerialSetting) -> String {
        guard let value = rigSerialDefaults[setting] else { return RigSerialConfig.defaultValue }
        return "\(RigSerialConfig.defaultValue) (\(setting.displayName(for: value)))"
    }

    private func loadSerialDefaults(model: Int?) {
        rigSerialDefaults = [:]
        guard let model else { return }
        Task.detached {
            let defaults = RigController.serialDefaults(model: model)
            await MainActor.run {
                // Ignore a lookup for a model that's since been changed.
                if self.selectedRigModel == model {
                    self.rigSerialDefaults = defaults
                }
            }
        }
    }

    private func loadState() {
        callsign = settings.callsign
        capitalizeMessages = settings.capitalizeMessages
        appendCallsign = settings.appendCallsign

        inputDevices = AudioDeviceLister.inputDevices()
        outputDevices = AudioDeviceLister.outputDevices()
        selectedInputUID = settings.audioInputDeviceUID ?? AudioDeviceLister.defaultInputDevice()?.uid
        selectedOutputUID = settings.audioOutputDeviceUID ?? AudioDeviceLister.defaultOutputDevice()?.uid
        inputGainDb = settings.audioInputGainDb
        outputGainDb = settings.audioOutputGainDb

        selectedRigModel = settings.rigModel
        rigPort = settings.rigPort
        rigSerial = settings.rigSerial
        rigMode = settings.rigMode
        discoveredPorts = Self.listSerialPorts()

        isLoadingRigs = true
        Task.detached {
            let rigs = RigController.availableRigs()
            await MainActor.run {
                self.rigs = rigs
                self.isLoadingRigs = false
            }
        }
    }

    private func connectToRig() {
        guard let model = selectedRigModel else {
            rigStatusIsError = true
            rigStatusText = "Select a rig model first."
            return
        }

        let port = rigPort.trimmingCharacters(in: .whitespaces)
        let serial = rigSerial
        let mode = rigMode
        isConnecting = true
        rigStatusIsError = false
        rigStatusText = "Connecting..."

        Task.detached {
            let result = RigController.connectAndQuery(model: model, port: port, serial: serial, setMode: mode)
            await MainActor.run {
                self.rigStatusText = result.message
                self.rigStatusIsError = !result.success
                self.isConnecting = false
            }
        }
    }

    private func save() {
        settings.callsign = callsign
        settings.capitalizeMessages = capitalizeMessages
        settings.appendCallsign = appendCallsign
        settings.audioInputDeviceUID = selectedInputUID
        settings.audioOutputDeviceUID = selectedOutputUID
        settings.audioInputGainDb = inputGainDb
        settings.audioOutputGainDb = outputGainDb
        settings.rigModel = selectedRigModel
        settings.rigPort = rigPort.trimmingCharacters(in: .whitespaces)
        settings.rigSerial = rigSerial
        settings.rigMode = rigMode
        settings.save()

        // Audio device choices may have changed; restart capture against
        // whatever is now configured.
        viewModel.restartReceiver()
        // Likewise the rig: reconnect, applying the (possibly new) mode.
        viewModel.reconnectRig()
        dismiss()
    }

    // macOS serial devices appear as /dev/cu.* (the "call-up" variant,
    // which doesn't wait for carrier detect - the right choice for CAT
    // control); plus rigctld's default address for the "Hamlib NET rigctl"
    // model.
    private static func listSerialPorts() -> [String] {
        var ports: [String] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
            ports = names.filter { $0.hasPrefix("cu.") }.sorted().map { "/dev/" + $0 }
        }
        ports.append("localhost:4532")
        return ports
    }
}

/// A push button that reports when it's pressed and released, for actions
/// that last as long as the button is held down. A Button's own action
/// only fires on release. Drawn by hand, since a ButtonStyle can't reuse
/// the system bezel, but sized to sit alongside standard push buttons.
private struct HoldButtonStyle: ButtonStyle {
    let onPressChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        HoldButton(configuration: configuration, onPressChanged: onPressChanged)
    }

    private struct HoldButton: View {
        let configuration: Configuration
        let onPressChanged: (Bool) -> Void
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 14)
                .padding(.vertical, 3)
                .foregroundStyle(configuration.isPressed ? Color.white : Color.primary)
                .background(configuration.isPressed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .opacity(isEnabled ? 1 : 0.5)
                .onChange(of: configuration.isPressed) { _, isPressed in
                    onPressChanged(isPressed)
                }
        }
    }
}

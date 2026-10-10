import SwiftUI

/// The Settings window: callsign, audio input/output device choice, and a
/// Transceiver section for Hamlib rig control (model, port, baud rate, and
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

    @State private var rigs: [RigInfo] = []
    @State private var isLoadingRigs = false
    @State private var selectedRigModel: Int?
    @State private var rigPort = ""
    @State private var discoveredPorts: [String] = []
    @State private var rigBaudRate = AppSettings.defaultBaudRate

    @State private var isConnecting = false
    @State private var rigStatusText = ""
    @State private var rigStatusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("Callsign:", text: $callsign, prompt: Text("e.g. W1AW"))
                Toggle("Capitalise messages", isOn: $capitalizeMessages)
                Toggle("Append callsign", isOn: $appendCallsign)
            }

            GroupBox("Transceiver") {
                Form {
                    Picker("Audio Input:", selection: $selectedInputUID) {
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }

                    Picker("Audio Output:", selection: $selectedOutputUID) {
                        ForEach(outputDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }

                    Picker("Rig Model:", selection: $selectedRigModel) {
                        Text(isLoadingRigs ? "Loading..." : "None").tag(Int?.none)
                        ForEach(rigs) { rig in
                            Text(rig.label).tag(Optional(rig.model))
                        }
                    }

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

                    Picker("Rig Baud Rate:", selection: $rigBaudRate) {
                        ForEach(AppSettings.baudRates, id: \.self) { rate in
                            Text(rate).tag(rate)
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
                }
                .padding(8)
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
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loadState() }
    }

    private func loadState() {
        callsign = settings.callsign
        capitalizeMessages = settings.capitalizeMessages
        appendCallsign = settings.appendCallsign

        inputDevices = AudioDeviceLister.inputDevices()
        outputDevices = AudioDeviceLister.outputDevices()
        selectedInputUID = settings.audioInputDeviceUID ?? AudioDeviceLister.defaultInputDevice()?.uid
        selectedOutputUID = settings.audioOutputDeviceUID ?? AudioDeviceLister.defaultOutputDevice()?.uid

        selectedRigModel = settings.rigModel
        rigPort = settings.rigPort
        rigBaudRate = settings.rigBaudRate.isEmpty ? AppSettings.defaultBaudRate : settings.rigBaudRate
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
        let baudRate = rigBaudRate
        isConnecting = true
        rigStatusIsError = false
        rigStatusText = "Connecting..."

        Task.detached {
            let result = RigController.connectAndQuery(model: model, port: port, baudRate: baudRate)
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
        settings.rigModel = selectedRigModel
        settings.rigPort = rigPort.trimmingCharacters(in: .whitespaces)
        settings.rigBaudRate = rigBaudRate
        settings.save()

        // Audio device choices may have changed; restart capture against
        // whatever is now configured.
        viewModel.restartReceiver()
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

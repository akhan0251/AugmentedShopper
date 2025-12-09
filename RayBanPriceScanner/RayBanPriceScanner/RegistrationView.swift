import SwiftUI
import MWDATCore

/// Lightweight registration UI to mirror the sample app flow.
struct RegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: WearablesViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                statusRow

                Button {
                    viewModel.connectGlasses()
                } label: {
                    Label("Connect / Register", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.disconnectGlasses()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if viewModel.devices.isEmpty {
                    Text("No devices found yet. Make sure Meta AI is installed, the glasses are connected, and Developer Mode is on.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detected devices")
                            .font(.subheadline.weight(.semibold))
                        ForEach(viewModel.devices, id: \.self) { device in
                            Text(device)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Register Glasses")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {
                    viewModel.dismissError()
                }
            } message: {
                Text(viewModel.errorMessage)
            }
        }
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            Text("Status: \(statusText)")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        switch viewModel.registrationState {
        case .registered: return "Registered"
        case .registering: return "Registering…"
        default: return "Not registered"
        }
    }

    private var statusColor: Color {
        switch viewModel.registrationState {
        case .registered: return .green
        case .registering: return .orange
        default: return .red
        }
    }
}

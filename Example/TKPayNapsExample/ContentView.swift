import SwiftUI
import TKPayNaps

struct ContentView: View {
    @StateObject private var viewModel = PaymentViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    configurationSection
                    paymentSection
                    actionsSection
                    if viewModel.showResult {
                        resultSection
                    }
                }
                .padding()
            }
            .navigationTitle("TKPay NAPS")
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Terminal Configuration")
                .font(.headline)

            HStack {
                TextField("Host IP", text: $viewModel.host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)

                TextField("Port", text: $viewModel.port)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
            }

            Button(action: viewModel.testConnection) {
                HStack {
                    if viewModel.isTesting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                    Text(viewModel.connectionStatus)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isTesting)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var paymentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Payment Details")
                .font(.headline)

            HStack {
                Text("Amount (MAD)")
                    .foregroundColor(.secondary)
                Spacer()
                TextField("0.00", text: $viewModel.amount)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Register ID")
                    .foregroundColor(.secondary)
                Spacer()
                TextField("01", text: $viewModel.registerId)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Cashier ID")
                    .foregroundColor(.secondary)
                Spacer()
                TextField("00001", text: $viewModel.cashierId)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var actionsSection: some View {
        Button(action: viewModel.processPayment) {
            HStack {
                if viewModel.isProcessing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
                Text(viewModel.isProcessing ? "Processing..." : "Process Payment")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.isProcessing || viewModel.amount.isEmpty)
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Result")
                    .font(.headline)
                Spacer()
                Image(systemName: viewModel.paymentResult?.isApproved == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(viewModel.paymentResult?.isApproved == true ? .green : .red)
            }

            if let result = viewModel.paymentResult {
                Group {
                    if result.isApproved {
                        resultRow("Status", "Approved")
                        if let stan = result.stan {
                            resultRow("STAN", stan)
                        }
                        if let card = result.maskedCardNumber {
                            resultRow("Card", card)
                        }
                        if let expiry = result.formattedExpiry {
                            resultRow("Expiry", expiry)
                        }
                        if let name = result.cardholderName {
                            resultRow("Cardholder", name)
                        }
                        if let auth = result.authNumber {
                            resultRow("Auth #", auth)
                        }
                    } else {
                        resultRow("Status", "Declined")
                        resultRow("Code", result.responseCode ?? "Unknown")
                        if let error = result.error {
                            resultRow("Error", error)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

@MainActor
class PaymentViewModel: ObservableObject {
    @Published var host = "192.168.24.214"
    @Published var port = "4444"
    @Published var amount = "100.00"
    @Published var registerId = "01"
    @Published var cashierId = "00001"

    @Published var isProcessing = false
    @Published var isTesting = false
    @Published var connectionStatus = "Test Connection"

    @Published var showResult = false
    @Published var paymentResult: PaymentResult?

    @Published var showError = false
    @Published var errorMessage = ""

    private var client: NapsPayClient {
        let config = NapsConfig(
            host: host,
            port: Int(port) ?? 4444
        )
        return NapsPayClient(config: config)
    }

    func testConnection() {
        isTesting = true
        connectionStatus = "Testing..."

        Task {
            let result = await client.testConnection()
            isTesting = false
            connectionStatus = result ? "Connected" : "Connection Failed"

            try? await Task.sleep(nanoseconds: 3_000_000_000)
            connectionStatus = "Test Connection"
        }
    }

    func processPayment() {
        guard let amountValue = Double(amount), amountValue > 0 else {
            showError("Invalid amount")
            return
        }

        guard registerId.count == 2 else {
            showError("Register ID must be 2 digits")
            return
        }

        guard cashierId.count == 5 else {
            showError("Cashier ID must be 5 digits")
            return
        }

        isProcessing = true
        showResult = false

        Task {
            do {
                let request = PaymentRequest(
                    amount: amountValue,
                    registerId: registerId,
                    cashierId: cashierId
                )

                let result = try await client.processPayment(request)
                paymentResult = result
                showResult = true
            } catch {
                showError(error.localizedDescription)
            }

            isProcessing = false
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

#Preview {
    ContentView()
}

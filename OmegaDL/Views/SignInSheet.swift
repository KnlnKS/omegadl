import MegaKit
import SwiftUI

struct SignInSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var secondFactor = ""
    @State private var needsSecondFactor = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?
    @Environment(\.fluidAnimation) private var fluidAnimation

    private enum Field {
        case email
        case password
        case secondFactor
    }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && !isWorking
            && (!needsSecondFactor || secondFactor.count >= 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign In to MEGA")
                    .font(.headline)
                Text("Your password never leaves this Mac. OmegaDL derives your keys locally.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Email").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("you@example.com", text: $email)
                        .textContentType(.username)
                        .focused($focus, equals: .email)
                }
                GridRow {
                    Text("Password").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    SecureField("Required", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                }
                if needsSecondFactor {
                    GridRow {
                        Text("Code").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                        TextField("6-digit code", text: $secondFactor)
                            .focused($focus, equals: .secondFactor)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)
            .disabled(isWorking)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Deriving keys…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Sign In", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focus = .email }
        .animation(fluidAnimation, value: needsSecondFactor)
        .animation(fluidAnimation, value: errorMessage)
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        errorMessage = nil

        Task {
            defer { isWorking = false }
            do {
                let credentials = AccountCredentials(
                    email: email,
                    password: password,
                    secondFactorCode: needsSecondFactor ? secondFactor : nil
                )
                let session = try await MegaLogin.logIn(credentials, api: APIClient())
                try model.signIn(with: session)
                dismiss()
            } catch MegaError.api(.multiFactorRequired) {
                needsSecondFactor = true
                focus = .secondFactor
                errorMessage = "Enter the code from your authenticator app."
            } catch MegaError.api(.notFound), MegaError.api(.badArguments) {
                errorMessage = "Incorrect email or password."
            } catch MegaError.api(.tooMany) {
                errorMessage = "Too many sign-in attempts. Wait a few minutes and try again."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Eight Sleep account")
                }

                Section {
                    Button {
                        Task { await model.signIn(email: email, password: password) }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isBusy { ProgressView() } else { Text("Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || model.isBusy)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = model.errorMessage {
                            Text(error).foregroundStyle(.red)
                        }
                        Text("Your login is stored only in this iPhone's Keychain. The watch receives a session token, never your password.")
                        Text("Unofficial — uses Eight Sleep's private cloud API.")
                    }
                }
            }
            .navigationTitle("Eight Sleep Remote")
        }
    }
}

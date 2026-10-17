import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Spacer(minLength: 32)
                    Text("EIGHT SLEEP")
                        .font(.caption.weight(.bold)).tracking(3)
                        .foregroundStyle(Theme.cool)
                    Text("Eight Sleep\nRemote")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Sign in, pick your side, and change the bed from your wrist.")
                        .font(.title3).foregroundStyle(Theme.muted)
                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                    .textFieldStyle(RemoteFieldStyle())
                    Button {
                        Task {
                            await model.signIn(email: email, password: password)
                            if model.isSignedIn { password = "" }
                        }
                    } label: {
                        Group {
                            if model.isBusy { ProgressView().tint(.white) }
                            else { Text("Sign in").font(.headline) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.cool, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(email.isEmpty || password.isEmpty || model.isBusy)
                    if let error = model.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(Theme.warm)
                    }
                    Text("Your password stays in this iPhone’s Keychain. Your watch receives tokens only.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Spacer(minLength: 32)
                    Text("Unofficial — uses Eight Sleep’s private cloud API.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(24)
                .frame(minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.background)
        .foregroundStyle(.white)
    }
}

private struct RemoteFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.padding(18).background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

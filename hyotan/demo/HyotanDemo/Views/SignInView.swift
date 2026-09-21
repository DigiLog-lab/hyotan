import SwiftUI

struct SignInView: View {
    @Environment(Machine.self) private var machine
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Sign in with ChatGPT")
                .font(.system(size: 28, weight: .semibold))

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        Text("Enter this code in your browser")
                            .font(.footnote)
                            .foregroundStyle(Palette.sub)
                        Text(machine.login?.userCode ?? "····-····")
                            .font(.mono(30, weight: .medium))
                            .kerning(3)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("signin-code")
                        Button("Copy code") {
                            UIPasteboard.general.string = machine.login?.userCode
                        }
                        .buttonStyle(.glass)
                        .disabled(machine.login == nil)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(22)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))

                    Button {
                        if let login = machine.login, let url = URL(string: login.verificationURL) { openURL(url) }
                    } label: {
                        Text("Open browser")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(machine.login == nil)
                    .accessibilityIdentifier("signin-open")
                }
            }

            if let error = machine.loginError {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).font(.footnote).foregroundStyle(Palette.red)
                    Button("Try again") { machine.beginLogin() }.buttonStyle(.glass)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(machine.login == nil ? "Requesting a code" : "Waiting for sign-in")
                        .font(.footnote)
                        .foregroundStyle(Palette.sub)
                }
            }
            Spacer()
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 28)
        .padding(.top, 72)
        .task { machine.beginLogin() }
        .accessibilityIdentifier("signin-screen")
    }
}

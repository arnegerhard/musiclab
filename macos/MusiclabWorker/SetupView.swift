import SwiftUI

/// First run: six characters, and nothing else to think about.
///
/// Deliberately not a sign-in. This Mac gets a credential of its own that can
/// claim work and hand it back and nothing else, so the account's password
/// never reaches it -- and an account that signed up with Apple, and therefore
/// has no password at all, can still put a Mac to work.
struct SetupView: View {
    var onSignedIn: () -> Void

    /// Where the code is redeemed. Not a field: someone reading a code off a
    /// phone has no idea what to type here, and getting it wrong is the one
    /// way to make a correct code look broken.
    private let server = "https://arnegerhard--musiclab-web.modal.run"

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    private var characters: [Character] { Array(code) }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Pair this Mac").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Musiclab on your phone: Settings, then Pair a Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            boxes

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button {
                    // Reading a code off a phone and typing it is the slow
                    // path; most people will have copied it.
                    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
                    accept(pasted)
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                Button("Pair") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || characters.count < Self.length)
            }

            Button("Cancel") { dismiss() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { focused = true }
        .onDisappear {
            // Back to an accessory once the window is gone, so the app leaves
            // no Dock icon behind.
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private static let length = 6

    /// Six rectangles with the dash in the middle, matching how the phone
    /// prints the code, so the two read as the same thing.
    private var boxes: some View {
        ZStack {
            // One real field behind the drawing takes the keystrokes; the
            // boxes are only a picture of it. Six separate fields would fight
            // each other over focus on every character.
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($focused)
                .opacity(0.02)
                .onChange(of: code) { _, new in accept(new) }
                .onSubmit { Task { await connect() } }

            HStack(spacing: 6) {
                ForEach(0..<Self.length, id: \.self) { index in
                    if index == Self.length / 2 {
                        Text("-")
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                    box(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        .onTapGesture { focused = true }
    }

    private func box(at index: Int) -> some View {
        let letter = index < characters.count ? String(characters[index]) : ""
        let isNext = index == characters.count
        return Text(letter)
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .frame(width: 34, height: 44)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7).strokeBorder(
                    isNext && focused ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: isNext && focused ? 2 : 1
                )
            )
    }

    /// Accepts the code however it arrives -- typed, pasted with the dash,
    /// pasted in lower case, pasted with the whole line around it.
    private func accept(_ text: String) {
        let cleaned = text.uppercased().filter { $0.isLetter || $0.isNumber }
        code = String(cleaned.prefix(Self.length))
        error = nil
        if code.count == Self.length {
            Task { await connect() }
        }
    }

    /// Trades the code for this machine's own token, and keeps only the token.
    private func connect() async {
        guard code.count == Self.length, !working else { return }
        working = true
        error = nil
        defer { working = false }

        guard let url = URL(string: server)?
            .appendingPathComponent("api/auth/pair/claim")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["code": code, "label": Host.current().localizedName ?? "A Mac"]
        )
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard http.statusCode == 200, let token = payload?["token"] as? String else {
                error = (payload?["detail"] as? String)
                    ?? "That code was not accepted. Codes last ten minutes and work once."
                code = ""
                return
            }
            Keychain.write(token)
            try WorkerProcess.save(
                configuration: .init(server: server, label: Host.current().localizedName)
            )
            onSignedIn()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

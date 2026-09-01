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
    /// The code already sent, so it is never spent twice.
    @State private var attempted = ""
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
                    // The code is copied on the phone, so it only reaches this
                    // clipboard through Universal Clipboard. When that has not
                    // happened the clipboard holds something else entirely --
                    // and pasting it must not wipe what was already typed.
                    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
                    // Measured before truncating: a pasted URL has plenty of
                    // letters and would otherwise pass as a code, get sent,
                    // and be rejected -- which is exactly how a paste ended up
                    // wiping the field.
                    let cleaned = Self.letters(pasted)
                    if cleaned.count == Self.length {
                        accept(cleaned)
                    } else {
                        error = pasted.isEmpty
                            ? "Nothing on the clipboard. Copy the code on your phone, or type it."
                            : "The clipboard does not hold a six-character code."
                    }
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

    /// Every character a code could be made of, in order, with nothing
    /// dropped. Truncating here would make any long string look like a code.
    static func letters(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func clean(_ text: String) -> String {
        String(letters(text).prefix(length))
    }

    /// Accepts the code however it arrives -- typed, pasted with the dash,
    /// pasted in lower case, pasted with the whole line around it.
    private func accept(_ text: String) {
        code = Self.clean(text)
        error = nil
        // A code is good for exactly one claim, and this is reached from both
        // typing and pasting. Trying the same six characters twice would spend
        // the code on the first attempt and report the second one's failure.
        guard code.count == Self.length, code != attempted, !working else { return }
        attempted = code
        Task { await connect() }
    }

    /// Trades the code for this machine's own token, and keeps only the token.
    private func connect() async {
        guard code.count == Self.length, !working else { return }
        attempted = code
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

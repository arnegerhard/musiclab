import SwiftUI

/// Spotify needs a client ID from your own developer dashboard, because the
/// app signs in as you rather than through a shared service account.
struct SpotifySetupView: View {
    let spotify: SpotifySource

    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Spotify client ID")
                } footer: {
                    Text("""
                    Create an app at developer.spotify.com/dashboard, then add \
                    this exact redirect URI to it:

                    \(SpotifySource.redirectURI)

                    Spotify never exposes audio, so this only reads your \
                    playlist names and track titles.
                    """)
                }
            }
            .navigationTitle("Connect Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        spotify.clientID = clientID.trimmingCharacters(in: .whitespaces)
                        dismiss()
                        Task { await spotify.connect() }
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { clientID = spotify.clientID }
        }
    }
}

import SwiftUI
import UIKit

/// Where the Mac helper is published. One constant, because it appears in the
/// welcome sheet, gets copied to a clipboard, and will outlive this screen.
enum WorkerDownload {
    static let url = "https://downloads.jetsons.info/Musiclab-Worker.zip"
    static let size = "330 MB"
}

/// Shown once, after the first sign-in, because everything that makes this app
/// unusual is invisible from the library: that a song becomes seven tracks,
/// that separating happens somewhere else, and that where it happens is a
/// choice with consequences. Left to discover it themselves, people meet the
/// choice for the first time in a menu on the Add screen with no way to judge
/// it.
struct WelcomeView: View {
    let onDone: () -> Void
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("A song comes in. Seven tracks come out — vocals, "
                         + "guitar, piano, bass, drums — and you can move each "
                         + "one around you as it plays.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    diagram

                    VStack(alignment: .leading, spacing: 18) {
                        Text("Separating is the heavy part")
                            .font(.headline)

                        option(
                            symbol: "desktopcomputer",
                            tint: .blue,
                            title: "On your Mac",
                            detail: "Free, and the only way to use a link. "
                                  + "Needs the helper app below, left running."
                        )
                        option(
                            symbol: "bolt.horizontal.circle",
                            tint: .orange,
                            title: "On Modal",
                            detail: "A few cents a song, no Mac needed — but it "
                                  + "can only take files you already have."
                        )
                    }

                    download
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Musiclab")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).bold()
                }
            }
        }
    }

    /// Deliberately not a picture of the audio. The thing worth drawing is the
    /// shape of the system: one song, two places it can be split, and a phone
    /// that ends up holding the result either way. The fork has to be drawn
    /// properly -- a plain vertical line between two nodes of different widths
    /// reads as "song, then Mac", with Modal standing off to one side.
    private var diagram: some View {
        VStack(spacing: 0) {
            node(symbol: "music.note", label: "A song", tint: .secondary)
            Branch(spreading: true)
                .stroke(.tertiary, lineWidth: 1.5)
                .frame(height: 26)
            HStack(spacing: 0) {
                node(symbol: "desktopcomputer", label: "Your Mac", tint: .blue)
                    .frame(maxWidth: .infinity)
                node(symbol: "bolt.horizontal.circle", label: "Modal", tint: .orange)
                    .frame(maxWidth: .infinity)
            }
            Branch(spreading: false)
                .stroke(.tertiary, lineWidth: 1.5)
                .frame(height: 26)
            node(symbol: "iphone", label: "Seven stems, here", tint: .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    /// One line splitting into two, or two rejoining into one. The quarter
    /// points are where the two nodes centre, each holding half the width.
    private struct Branch: Shape {
        let spreading: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let left = rect.width * 0.25, right = rect.width * 0.75
            let midY = rect.midY
            let stem = spreading ? rect.minY : rect.maxY
            let arms = spreading ? rect.maxY : rect.minY

            path.move(to: CGPoint(x: rect.midX, y: stem))
            path.addLine(to: CGPoint(x: rect.midX, y: midY))
            path.move(to: CGPoint(x: left, y: midY))
            path.addLine(to: CGPoint(x: right, y: midY))
            path.move(to: CGPoint(x: left, y: midY))
            path.addLine(to: CGPoint(x: left, y: arms))
            path.move(to: CGPoint(x: right, y: midY))
            path.addLine(to: CGPoint(x: right, y: arms))
            return path
        }
    }

    private func node(symbol: String, label: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(height: 26)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func option(
        symbol: String, tint: Color, title: String, detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A link rather than a button, because the download is for a different
    /// machine than the one reading this. Copying it is the useful action; a
    /// tap that opens Safari on the phone would start 323 MB going nowhere.
    private var download: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The Mac helper")
                .font(.headline)
            Text("Open this on your Mac. It sits in the menu bar, and the app "
                 + "finds it on your network — nothing to type.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: copy) {
                HStack(spacing: 10) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkerDownload.url)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(copied
                             ? "Copied — paste it into a browser on your Mac"
                             : "Tap to copy · \(WorkerDownload.size)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    /// The clipboard has to leave the phone: the whole point is to paste this
    /// on a Mac. Setting `.string` alone stays local, so this asks explicitly
    /// for a shared item, as the pairing code once had to.
    private func copy() {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": WorkerDownload.url]],
            options: [.localOnly: false]
        )
        withAnimation { copied = true }
    }
}

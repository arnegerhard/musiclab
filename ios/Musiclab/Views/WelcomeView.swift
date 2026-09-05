import SwiftUI
import UIKit

/// Where the Mac helper is published. One constant, because it appears in the
/// welcome sheet, gets copied to a clipboard, and will outlive this screen.
enum WorkerDownload {
    static let url = "https://downloads.jetsons.info/Musiclab-Worker.zip"
    /// Decimal megabytes, which is what Finder and the browser will say when
    /// this lands. The old figure was mebibytes wearing an MB label, so the
    /// download looked twelve megabytes bigger than promised on arrival.
    static let size = "342 MB"
}

/// Shown once, after the first sign-in, because everything that makes this app
/// unusual is invisible from the library: that a song becomes seven tracks,
/// that separating happens somewhere else, and that where it happens is a
/// choice with consequences. Left to discover it themselves, people meet the
/// choice for the first time in a menu on the Add screen with no way to judge
/// it.
struct WelcomeView: View {
    let onDone: () -> Void
    @Environment(StemsClient.self) private var client
    @Environment(JobQueue.self) private var queue

    @State private var copied = false
    @State private var browser = WorkerBrowser()
    @State private var session: PairingSession?
    @State private var pairingWith: WorkerBrowser.Found?

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

                    Text("A link means YouTube, Apple Music or Spotify. "
                         + "Fetching the audio from any of them needs a Mac: "
                         + "they refuse servers, and Modal is a server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 18) {
                        Text("Separating is the heavy part")
                            .font(.headline)

                        option(
                            symbol: "desktopcomputer",
                            tint: .blue,
                            title: "On your Mac",
                            detail: "Free, and the only route a link can "
                                  + "take. Needs the helper app below, left running."
                        )
                        option(
                            symbol: "bolt.horizontal.circle",
                            tint: .orange,
                            title: "On Modal",
                            detail: "A few cents a song and no Mac at all — "
                                  + "but only for files you already have."
                        )
                    }

                    download
                    pairing
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Musiclab")
            // The browser only runs while this sheet is up. A Mac that gets
            // opened while someone is reading this appears without a refresh.
            .task {
                browser.start()
                await queue.refresh()
            }
            .onDisappear {
                session?.cancel()
                browser.stop()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).bold()
                }
            }
        }
    }

    /// The point of the picture is which route a song can take, because that
    /// is the part that constrains what the app can do at all: a link can only
    /// be fetched by a Mac. Drawing it as one song splitting two ways said the
    /// two were interchangeable, which is the opposite of true.
    private var diagram: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                node(symbol: "link", label: "A link", tint: .secondary)
                    .frame(maxWidth: .infinity)
                node(symbol: "waveform", label: "A file you have", tint: .secondary)
                    .frame(maxWidth: .infinity)
            }
            Routes()
                .stroke(.tertiary, lineWidth: 1.5)
                .frame(height: 40)
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

    /// A link drops straight to the Mac and has nowhere else to go. A file
    /// drops to Modal and also sweeps across to the Mac.
    ///
    /// That second route is a curve of its own rather than a rung between the
    /// two verticals: a shared horizontal can be read in the other direction,
    /// as though a link could turn right and reach Modal, which is the one
    /// thing this picture exists to deny.
    private struct Routes: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let left = rect.width * 0.25, right = rect.width * 0.75
            path.move(to: CGPoint(x: left, y: rect.minY))
            path.addLine(to: CGPoint(x: left, y: rect.maxY))
            path.move(to: CGPoint(x: right, y: rect.minY))
            path.addLine(to: CGPoint(x: right, y: rect.maxY))
            path.move(to: CGPoint(x: right, y: rect.minY))
            path.addCurve(
                to: CGPoint(x: left, y: rect.maxY),
                control1: CGPoint(x: right, y: rect.midY),
                control2: CGPoint(x: left, y: rect.midY)
            )
            return path
        }
    }

    /// Two rejoining into one.
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
            Text("Open this on your Mac. It sits in the menu bar, and the "
                 + "app finds it on your network — nothing to type.\n\n"
                 + "Without it, this app can still separate audio files you "
                 + "pick from your phone. It cannot fetch anything from a "
                 + "link.")
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

    /// Pairing belongs next to the download, because it is the same errand:
    /// the helper is only useful once this phone has adopted it. Skippable --
    /// Done is always there, and the Queue tab does this too.
    @ViewBuilder
    private var pairing: some View {
        if let session {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pairing with \(session.macName)")
                    .font(.headline)
                pairingStep(session)
            }
        } else if !queue.machines.isEmpty {
            // A Mac that has already been adopted never advertises itself for
            // pairing again -- it starts working instead. Browsing alone
            // therefore shows nothing at the exact moment someone switches
            // their Mac on and looks here to see whether it worked.
            VStack(alignment: .leading, spacing: 10) {
                Text("Your Mac")
                    .font(.headline)
                ForEach(queue.machines) { machine in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(machine.indicator)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.name).font(.callout)
                            Text(machine.headline)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                if !browser.macs.isEmpty {
                    Text("And one offering to pair:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(browser.macs) { mac in pairRow(mac) }
                }
            }
        } else if !browser.macs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("It is running")
                    .font(.headline)
                Text("Found on this network. Pairing takes a moment, and the "
                     + "Mac will ask before it agrees.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(browser.macs) { mac in pairRow(mac) }
            }
        } else {
            Text("Once it is open on your Mac, it will appear here to pair. "
                 + "You can also do that later, from the Queue tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pairRow(_ mac: WorkerBrowser.Found) -> some View {
        Button { start(with: mac) } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").foregroundStyle(.blue)
                Text(mac.name).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("Pair").font(.callout).bold().foregroundStyle(.blue)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pairingStep(_ session: PairingSession) -> some View {
        switch session.step {
        case .connecting:
            labelled("Connecting…")
        case let .confirm(number):
            VStack(spacing: 10) {
                Text(number)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                Text("Pair only if \(session.macName) is showing these same "
                     + "six digits.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Cancel", role: .cancel) { stop() }
                    Spacer()
                    Button("Pair") { session.confirm() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
        case let .waitingForMac(number):
            VStack(spacing: 8) {
                Text(number)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                labelled("Waiting for \(session.macName) to allow it…")
            }
            .frame(maxWidth: .infinity)
        case .handingOver:
            labelled("Setting it up…")
        case .paired:
            Label("\(session.macName) is ready to work",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .task {
                    if let mac = pairingWith { browser.hide(mac) }
                    self.session = nil
                    self.pairingWith = nil
                }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
                Button("Try again") { stop() }
            }
        }
    }

    private func labelled(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func start(with mac: WorkerBrowser.Found) {
        pairingWith = mac
        session = PairingSession(mac: mac) { try await client.mintPairingCode() }
    }

    private func stop() {
        session?.cancel()
        session = nil
        pairingWith = nil
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

import AuthenticationServices
import Foundation
import Observation

/// Signing in, signing up, Apple, and password reset.
@Observable
final class Account: NSObject {
    struct User: Codable, Equatable {
        let id: String
        let email: String?
        let displayName: String?
        let hasPassword: Bool
        let appleLinked: Bool

        enum CodingKeys: String, CodingKey {
            case id, email
            case displayName = "display_name"
            case hasPassword = "has_password"
            case appleLinked = "apple_linked"
        }
    }

    private struct Session: Decodable { let token: String; let user: User }
    private struct ServerError: Decodable { let detail: String }

    private(set) var user: User?
    private(set) var isWorking = false
    var error: String?

    private let client: StemsClient
    private var appleContinuation: CheckedContinuation<ASAuthorization, Error>?

    init(client: StemsClient) {
        self.client = client
        super.init()
    }

    var isSignedIn: Bool { user != nil }

    // MARK: - Requests

    private func post<Body: Encodable>(_ path: String, _ body: Body) async throws -> Session {
        var request = URLRequest(url: client.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StemsClient.ClientError.badResponse(0)
        }
        if http.statusCode != 200 {
            // The server writes messages meant to be read, so show them.
            let detail = (try? JSONDecoder().decode(ServerError.self, from: data))?.detail
            throw NSError(domain: "Musiclab", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail ?? "Something went wrong."])
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }

    private func adopt(_ session: Session) {
        client.token = session.token
        client.user = session.user
        user = session.user
        error = nil
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do { try await work() } catch { self.error = error.localizedDescription }
    }

    // MARK: - Email and password

    struct Credentials: Encodable {
        let email: String
        let password: String
        var display_name: String?
    }

    func signUp(email: String, password: String, name: String?) async {
        await run { adopt(try await post("api/auth/signup",
                                        Credentials(email: email, password: password,
                                                    display_name: name))) }
    }

    func signIn(email: String, password: String) async {
        await run { adopt(try await post("api/auth/login",
                                        Credentials(email: email, password: password))) }
    }

    // MARK: - Password reset

    struct ResetRequest: Encodable { let email: String }
    struct ResetConfirm: Encodable { let email: String; let code: String; let new_password: String }

    /// Succeeds whether or not the address has an account, matching the server.
    func requestReset(email: String) async -> Bool {
        guard let body = try? JSONEncoder().encode(ResetRequest(email: email))
        else { return false }
        var request = URLRequest(url: client.baseURL.appendingPathComponent("api/auth/reset/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func confirmReset(email: String, code: String, newPassword: String) async {
        await run { adopt(try await post("api/auth/reset/confirm",
                                        ResetConfirm(email: email, code: code,
                                                     new_password: newPassword))) }
    }

    // MARK: - Sign in with Apple

    struct AppleBody: Encodable {
        let identity_token: String
        var email: String?
        var display_name: String?
    }

    func signInWithApple() async {
        await run {
            let authorization = try await requestAppleCredential()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8)
            else { throw NSError(domain: "Musiclab", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Apple did not return a usable sign-in.",
            ]) }

            // Apple sends name and email only on the first authorisation ever,
            // so pass them along; the server keeps them if it has none.
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            adopt(try await post("api/auth/apple", AppleBody(
                identity_token: identityToken,
                email: credential.email,
                display_name: name.isEmpty ? nil : name
            )))
        }
    }

    private func requestAppleCredential() async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            appleContinuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Session lifecycle

    /// Ask the server who this stored token belongs to. Clears it if the
    /// session has expired or the server no longer knows it.
    @discardableResult
    func restore() async -> Bool {
        guard !client.token.isEmpty else {
            user = nil
            return false
        }
        let baseURL = client.baseURL
        let request = client.request(baseURL.appendingPathComponent("api/auth/me"))
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            // The question never reached the server, so nothing was learned
            // about the session. Keep it: a timeout in a tunnel is not a
            // sign-out, and throwing the token away means typing a password
            // to recover from a bad minute of signal.
            user = nil
            return false
        }
        guard http.statusCode == 200,
              let found = try? JSONDecoder().decode(User.self, from: data)
        else {
            // Only the server itself saying "not you" retires the token.
            if http.statusCode == 401 || http.statusCode == 403 {
                client.token = ""
            }
            user = nil
            return false
        }
        user = found
        client.user = found
        return true
    }

    /// Delete the account and everything separated for it.
    ///
    /// Irreversible, and the server takes the songs with it. Apple requires
    /// an app that can create an account to be able to remove one, and this
    /// is that.
    func deleteAccount() async -> Bool {
        guard !client.token.isEmpty else { return false }
        var request = client.request(client.baseURL.appendingPathComponent("api/auth/account"))
        request.httpMethod = "DELETE"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        client.clearCache()
        client.token = ""
        client.user = nil
        user = nil
        return true
    }

    func signOut() async {
        if !client.token.isEmpty {
            var request = client.request(client.baseURL.appendingPathComponent("api/auth/logout"))
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
        client.token = ""
        client.user = nil
        user = nil
    }
}

extension Account: ASAuthorizationControllerDelegate,
                   ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        appleContinuation?.resume(returning: authorization)
        appleContinuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        appleContinuation?.resume(throwing: error)
        appleContinuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

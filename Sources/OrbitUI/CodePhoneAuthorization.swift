#if os(iOS)
import UIKit
import OrbitCore

@MainActor public enum CodePhoneAuthorization {
    public static func choose(client: CodeClient, from controller: UIViewController, completed: @escaping (String) -> Void) {
        Task {
            do {
                guard let bundleID = Bundle.main.bundleIdentifier else { throw CodeFailure("The app identifier is unavailable.") }
                let identity = try CodeInstallEndpointIdentity(service: bundleID + ".installation")
                let bindings = try await client.call(CodeRequest(.endpointStatus)).endpointBindings ?? []
                let mine = bindings.filter { $0.publicKey == identity.publicKey }
                let devices = try await client.call(CodeRequest(.devices)).devices ?? []
                guard !devices.isEmpty || !mine.isEmpty else { throw CodeFailure("Connect this phone to your Mac and check device trust in Xcode first.") }
                let alert = UIAlertController(title: "Authorize This Phone", message: "Choose this phone while it’s connected to your Mac. Your Mac will verify it through Apple’s device connection.", preferredStyle: .actionSheet)
                for device in devices {
                    alert.addAction(UIAlertAction(title: device.name, style: .default) { _ in
                        Task {
                            do { try await authorize(deviceID: device.id, client: client); completed("This phone is authorized.") }
                            catch { completed(error.localizedDescription) }
                        }
                    })
                }
                for binding in mine {
                    alert.addAction(UIAlertAction(title: "Remove This Phone’s Authorization", style: .destructive) { _ in
                        Task {
                            do {
                                var request = CodeRequest(.endpointRevoke); request.endpoint = CodeEndpointEnrollmentRequest(id: binding.id)
                                _ = try await client.call(request); completed("This phone’s authorization was removed.")
                            } catch { completed(error.localizedDescription) }
                        }
                    })
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.popoverPresentationController?.sourceView = controller.view
                controller.present(alert, animated: true)
            } catch { completed(error.localizedDescription) }
        }
    }
    private static func authorize(deviceID: String, client: CodeClient) async throws {
        guard let bundleID = Bundle.main.bundleIdentifier else { throw CodeFailure("The app identifier is unavailable.") }
        let identity = try CodeInstallEndpointIdentity(service: bundleID + ".installation")
        let enrollment = CodeEndpointEnrollmentRequest(deviceID: deviceID, publicKey: identity.publicKey)
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let file = container.appendingPathComponent(try CodeEndpointEnrollment.path(id: enrollment.id, proof: false))
        // Create only our own private destination before the Apple copy. Choosing
        // a different phone cannot make its sandbox sign with this phone's key.
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        defer { CodeEndpointEnrollment.clean(container: container, id: enrollment.id) }
        var begin = CodeRequest(.endpointBegin); begin.endpoint = enrollment
        guard let receipt = try await client.call(begin).endpointChallenge,
              receipt.id == enrollment.id, receipt.deviceID == deviceID else { throw CodeFailure("The Mac returned a different phone authorization. Try again.") }
        try CodeEndpointEnrollment.writeProof(receipt: receipt, container: container, publicKey: identity.publicKey, sign: identity.sign)
        var finish = CodeRequest(.endpointFinish); finish.endpoint = CodeEndpointEnrollmentRequest(id: enrollment.id)
        guard let binding = try await client.call(finish).endpointBindings?.first,
              binding.id == enrollment.id, binding.publicKey == identity.publicKey, binding.deviceID == deviceID else { throw CodeFailure("The Mac couldn’t confirm this phone’s authorization.") }
    }
}
#endif

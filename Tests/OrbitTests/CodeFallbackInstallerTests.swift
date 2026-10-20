import XCTest
@testable import OrbitCore
@testable import OrbitMac

final class CodeFallbackInstallerTests: XCTestCase {
    private final class Installer: CodeArtifactInstalling, @unchecked Sendable {
        let result: CodeArtifactInstallResult
        private let lock = NSLock(); private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        init(_ state: CodeInstallAttempt.State, _ kind: CodeOvernightError.Kind? = nil) {
            result = CodeArtifactInstallResult(state: state, error: kind.map { CodeOvernightError($0, stage: "fixture", recovery: "fixture") })
        }
        func install(_ artifact: CodeBuildArtifact, app: URL, process: CodeProcess) async -> CodeArtifactInstallResult {
            lock.withCriticalScope { count += 1 }; return result
        }
    }
    func testFallbackRequiresNativeTransportFailureBeforeHandoff() async throws {
        let artifact = CodeBuildArtifact(id: UUID().uuidString, jobID: "job", target: CodeOvernightTarget(peerID: "mac", deviceID: "phone", project: CodeProject(path: "/tmp/fixture.xcodeproj", scheme: "Fixture"), branch: "main", generation: "g"), bundleID: "fixture", version: "1", build: "2", commit: "c", digest: "d", signingAuthority: "fixture", byteCount: 1)
        for (state, kind, expected) in [(CodeInstallAttempt.State.waitingForPhone, CodeOvernightError.Kind.transport, 1), (.unknownCompletion, .transport, 0), (.failed, .pairing, 0), (.failed, .signing, 0), (.failed, .identity, 0), (.failed, .locked, 0), (.waitingForPhone, .unknown, 0)] {
            let native = Installer(state, kind), remote = Installer(.succeeded)
            _ = await CodeFallbackInstaller(native: native, remote: remote).install(artifact, app: URL(fileURLWithPath: "/tmp/fixture.app"), process: CodeProcess())
            XCTAssertEqual(native.calls, 1); XCTAssertEqual(remote.calls, expected, "\(state)/\(kind)")
        }
    }
    func testRemoteReadbackAndDefinitiveErrorsPreserveUnknownCompletion() {
        func reply(_ handedOff: Bool, _ definitive: Bool, _ kind: String) -> CodeArtifactInstallResult {
            CodeReverseInstaller.result(CodeReverseInstaller.Reply(confirmed: false, handedOff: handedOff, definitiveFailure: definitive, stage: "install", kind: kind, error: nil), description: "fixture")
        }
        XCTAssertEqual(reply(true, false, "transport").state, .unknownCompletion)
        XCTAssertEqual(reply(false, false, "transport").state, .waitingForPhone)
        XCTAssertEqual(reply(true, true, "signing").state, .failed)
        XCTAssertEqual(reply(false, false, "identity").error?.kind, .identity)
    }
}

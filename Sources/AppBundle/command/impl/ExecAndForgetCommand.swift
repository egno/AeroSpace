import AppKit
import Common

struct ExecAndForgetCommand: Command {
    let args: ExecAndForgetCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // todo shall exec-and-forget fork exec session?
        .from(bool: execAndForget(args.bashScript, env: env.asMap))
    }
}

/// It doesn't throw if exit code is non-zero
@MainActor func execAndForget(_ bashScript: String, env: [String: String]) -> Bool {
    let process = Process()
    process.environment = config.execConfig.envVariables + env
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = ["-c", bashScript]
    return Result { try process.run() }.isSuccess
}

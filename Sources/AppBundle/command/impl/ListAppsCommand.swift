import AppKit
import Common

struct ListAppsCommand: Command {
    let args: ListAppsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        var result = Array(MacApp.allAppsMap.values)
        if let hidden = args.macosHidden {
            result = result.filter { $0.nsApp.isHidden == hidden }
        }
        if let pid = args.pidFilter {
            result = result.filter { $0.pid == pid }
        }
        if let projectFilter = args.projectFilter {
            result = result.filter { projectFilter.matches($0) }
        }

        lazy var list = result.map(AeroObj.app)
        return switch true {
            case args.outputOnlyCount:
                .succ(io.out("\(result.count)"))
            case args.json:
                switch list.formatToJson(args.format, ignoreRightPaddingVar: args._format.isEmpty) {
                    case .success(let json): .succ(io.out(json))
                    case .failure(let msg): .fail(io.err(msg))
                }
            default:
                switch list.format(args.format) {
                    case .success(let lines): .succ(io.out(lines))
                    case .failure(let msg): .fail(io.err(msg.map(\.description).joinErrors()))
                }
        }
    }
}

public struct ProjectCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .project,
        help: project_help_generated,
        flags: [
            "--none": trueBoolFlag(\.none),
            "--wrap-around": trueBoolFlag(\.wrapAround),
            "--launch-missing": trueBoolFlag(\.launchMissing),
        ],
        posArgs: [
            dashDashArg(mandatory: false),
            ArgParser(\._target, upcastArgParserFun(parseProjectTarget)),
        ],
        conflictingOptions: [
            ["--none", "--wrap-around"],
            ["--none", "--launch-missing"],
        ],
    )

    public var _target: ProjectTarget? = nil
    fileprivate var none: Bool = false
    public var wrapAround: Bool = false
    public var launchMissing: Bool = false
}

extension ProjectCmdArgs {
    public var target: ProjectTarget { _target ?? .noProject }
}

func parseProjectCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ProjectCmdArgs> {
    parseSpecificCmdArgs(ProjectCmdArgs(rawArgs: args), args)
        .filter("Either <project-name>, \(NextPrev.unionLiteral) or --none must be specified") { $0.none || $0._target != nil }
        .filterNot("--none is incompatible with <project-name> and \(NextPrev.unionLiteral)") { $0.none && $0._target != nil }
        .filter("--wrap-around requires using \(NextPrev.unionLiteral) argument") { $0.wrapAround.implies($0.target.isRelative) }
}

public enum ProjectTarget: Equatable, Sendable {
    case relative(NextPrev)
    case direct(String)
    case noProject

    public var isRelative: Bool {
        switch self {
            case .relative: true
            case .direct, .noProject: false
        }
    }
}

func parseProjectTarget(i: PosArgParserInput) -> ParsedCliArgs<ProjectTarget> {
    switch (i.arg, i.sawDashDash) {
        case ("next", false): .succ(.relative(.next), advanceBy: 1)
        case ("prev", false): .succ(.relative(.prev), advanceBy: 1)
        default: .init(parseProjectName(i.arg).map(ProjectTarget.direct), advanceBy: 1)
    }
}

func parseProjectNamePosArg(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .init(parseProjectName(i.arg), advanceBy: 1)
}

/// Project names are used in regexes and shell commands via `{project}` substitution. Keep them safe
public func parseProjectName(_ raw: String) -> ResOrStr<String> {
    !raw.isEmpty && raw.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" || $0 == "-" })
        ? .success(raw)
        : .failure("Project name '\(raw)' must match [a-z0-9_-]+ regex")
}

public enum ProjectFilter: Equatable, Sendable {
    case name(String)
    case global
    case active
}

let projectFilterPlaceholder = "(<project-name>|--none|--active)"

func projectFilterSubArgParser<Root>(_ keyPath: SendableWritableKeyPath<Root, ProjectFilter?>) -> SubArgParser<Root, ProjectFilter?> {
    ArgParser(keyPath) { input in
        switch input.argOrNil {
            case nil: .fail("'\(input.superArg)' must be followed by '\(projectFilterPlaceholder)'", advanceBy: 0)
            case "--none": .succ(.global, advanceBy: 1)
            case "--active": .succ(.active, advanceBy: 1)
            case let arg? where arg.isCliDashFlag:
                .fail("'\(input.superArg)' must be followed by '\(projectFilterPlaceholder)'", advanceBy: 0)
            case let arg?:
                switch parseProjectName(arg) {
                    case .success(let name): .succ(.name(name), advanceBy: 1)
                    case .failure(let error): .fail("Failed to parse '\(arg)' CLI argument: \(error)", advanceBy: 1)
                }
        }
    }
}

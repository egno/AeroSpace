public struct MoveAppToProjectCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveAppToProject,
        help: move_app_to_project_help_generated,
        flags: [
            "--none": trueBoolFlag(\.none),
            "--pid": singleValueSubArgParser(\.pid, "<pid>") { Int32($0).toResult("Can't convert to Int32") },
        ],
        posArgs: [
            ArgParser(\.project, upcastArgParserFun(parseProjectNamePosArg)),
        ],
    )

    /// nil means --none (make the process global)
    public var project: String? = nil
    fileprivate var none: Bool = false
    public var pid: Int32? = nil
}

func parseMoveAppToProjectCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveAppToProjectCmdArgs> {
    parseSpecificCmdArgs(MoveAppToProjectCmdArgs(rawArgs: args), args)
        .filter("Either <project-name> or --none must be specified") { $0.none || $0.project != nil }
        .filterNot("--none is incompatible with <project-name>") { $0.none && $0.project != nil }
}

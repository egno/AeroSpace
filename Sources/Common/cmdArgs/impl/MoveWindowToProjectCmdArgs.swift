public struct MoveWindowToProjectCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveWindowToProject,
        help: move_window_to_project_help_generated,
        flags: [
            "--none": trueBoolFlag(\.none),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [
            ArgParser(\.project, upcastArgParserFun(parseProjectNamePosArg)),
        ],
    )

    /// nil means --none (make the window global)
    public var project: String? = nil
    fileprivate var none: Bool = false
}

func parseMoveWindowToProjectCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveWindowToProjectCmdArgs> {
    parseSpecificCmdArgs(MoveWindowToProjectCmdArgs(rawArgs: args), args)
        .filter("Either <project-name> or --none must be specified") { $0.none || $0.project != nil }
        .filterNot("--none is incompatible with <project-name>") { $0.none && $0.project != nil }
}

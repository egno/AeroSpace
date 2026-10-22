public struct ProjectQuitCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .projectQuit,
        help: project_quit_help_generated,
        flags: [:],
        posArgs: [
            ArgParser(\.project, upcastArgParserFun(parseProjectNamePosArg)),
        ],
    )

    public var project: String? = nil
}

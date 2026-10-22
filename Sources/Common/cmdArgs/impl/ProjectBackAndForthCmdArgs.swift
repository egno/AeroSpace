public struct ProjectBackAndForthCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .projectBackAndForth,
        help: project_back_and_forth_help_generated,
        flags: [:],
        posArgs: [],
    )
}

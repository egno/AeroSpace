public struct ListProjectsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .listProjects,
        help: list_projects_help_generated,
        flags: [
            "--active": trueBoolFlag(\.onlyActive),

            // Formatting flags
            "--format": formatParser(\._format, for: .project),
            "--count": trueBoolFlag(\.outputOnlyCount),
            "--json": trueBoolFlag(\.json),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--count", "--format"],
            ["--count", "--json"],
        ],
    )

    public var onlyActive: Bool = false
    public var _format: [InterToken<InterVar>] = []
    public var outputOnlyCount: Bool = false
    public var json: Bool = false
}

extension ListProjectsCmdArgs {
    public var format: [InterToken<InterVar>] {
        _format.isEmpty
            ? [
                .interVar(.formatVar(.project(.projectName))), .interVar(.plainInterVar(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.project(.projectIsActive))), .interVar(.plainInterVar(.rightPadding)), .literal(" | "),
                .interVar(.formatVar(.project(.projectRunningApps))),
            ]
            : _format
    }
}

func parseListProjectsCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListProjectsCmdArgs> {
    parseSpecificCmdArgs(ListProjectsCmdArgs(rawArgs: args), args)
        .flatMap { if $0.json, let msg = getErrorIfFormatIsIncompatibleWithJson($0._format) { .failure(msg) } else { .cmd($0) } }
}

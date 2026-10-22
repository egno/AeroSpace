public struct ProjectLaunchCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .projectLaunch,
        help: project_launch_help_generated,
        flags: [
            "--project": singleValueSubArgParser(\.project, "<project-name>", parseProjectName),
            "--app": ArgParser(\.appIds, nonEmptyNonFlagArgsParser("<app-id>...")),
            "--open": ArgParser(\.open, nonEmptyNonFlagArgsParser("<item>...")),
        ],
        posArgs: [],
    )

    public var project: String? = nil
    public var appIds: [String] = []
    public var open: [String] = []
}

func parseProjectLaunchCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ProjectLaunchCmdArgs> {
    parseSpecificCmdArgs(ProjectLaunchCmdArgs(rawArgs: args), args)
        .filter("--open requires exactly one <app-id> in --app") { $0.open.isEmpty || $0.appIds.count == 1 }
        .filter("Duplicated <app-id> in --app") { $0.appIds.count == $0.appIds.toSet().count }
}

private func nonEmptyNonFlagArgsParser(_ placeholder: String) -> @Sendable (SubArgParserInput) -> ParsedCliArgs<[String]> {
    { input in
        let args = input.nonFlagArgs()
        return args.isEmpty
            ? .fail("'\(input.superArg)' must be followed by '\(placeholder)'", advanceBy: 0)
            : .succ(args.toArray(), advanceBy: args.count)
    }
}

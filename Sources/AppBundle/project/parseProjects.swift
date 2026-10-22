import Common

let projectPlaceholder = "{project}"
let openPlaceholder = "{open}"

/// `[project-apps.<id>]`
struct ProjectAppDef: ConvenienceMutable, Equatable {
    var rawIf: String? = nil
    var launch: String? = nil
    var globalLaunch: String? = nil
    /// Used to find the global instance of the app (a process with this bundle ID that matches no project)
    var bundleId: String? = nil

    /// Shared app definitions contain `{project}` placeholder in their matcher.
    /// Each project that references a shared definition gets its own instance.
    /// Otherwise, it's a whole-app definition. All processes of the app belong to the single project that references it
    var isShared: Bool { rawIf?.contains(projectPlaceholder) == true }
}

/// An app definition referenced from a `[[projects]]` entry with `{project}` already substituted
struct ProjectApp {
    let appId: String
    let isShared: Bool
    let matcher: Shell<any Command>
    let launch: String?
    let autostart: Bool
    let open: [String]
}

struct Project {
    let name: String
    let apps: [ProjectApp]
    let linkBrowser: String?
}

enum InactiveProjectActivationPolicy: String, CaseIterable, Sendable {
    case _switch = "switch"
    case rehide
}

private struct RawProject: ConvenienceMutable {
    var name: String? = nil
    var apps: [RawProjectAppRef] = []
    var linkBrowser: String? = nil
}

private struct RawProjectAppRef: ConvenienceMutable {
    var index: Int = 0
    var appId: String? = nil
    var autostart: Bool = true
    var open: [String] = []
}

private let projectAppDefParser: [String: any ParserProtocol<ProjectAppDef>] = [
    "if": Parser(\.rawIf) { raw, backtrace in parseString(raw, backtrace).map(Optional.init) },
    "launch": Parser(\.launch) { raw, backtrace in parseString(raw, backtrace).map(Optional.init) },
    "global-launch": Parser(\.globalLaunch) { raw, backtrace in parseString(raw, backtrace).map(Optional.init) },
    "bundle-id": Parser(\.bundleId, parseBundleId),
]

private let rawProjectParser: [String: any ParserProtocol<RawProject>] = [
    "name": Parser(\.name) { raw, backtrace in parseString(raw, backtrace).map(Optional.init) },
    "apps": Parser(\.apps, parseRawProjectAppRefs),
    "link-browser": Parser(\.linkBrowser) { raw, backtrace in parseString(raw, backtrace).map(Optional.init) },
]

private let rawProjectAppRefParser: [String: any ParserProtocol<RawProjectAppRef>] = [
    "app": Parser(\.appId) { raw, backtrace in parseString(raw, backtrace).map(Optional.init) },
    "autostart": Parser(\.autostart, parseBool),
    "open": Parser(\.open, parseProjectArrayOfStrings),
]

func parseProjectAppDefs(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: ProjectAppDef] {
    guard let table = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: ProjectAppDef] = [:]
    for (id, rawDef) in table {
        let backtrace = backtrace + .key(id)
        let def = parseTable(rawDef, ProjectAppDef(), projectAppDefParser, backtrace, &c)
        if def.rawIf == nil {
            c.errors.append(.init(backtrace, "'if' is mandatory key"))
            continue
        }
        if def.globalLaunch?.contains(projectPlaceholder) == true {
            c.errors.append(.init(backtrace + .key("global-launch"), "'global-launch' must not contain \(projectPlaceholder) placeholder"))
        }
        if def.globalLaunch != nil && def.bundleId == nil {
            c.errors.append(.init(backtrace + .key("global-launch"), "'global-launch' requires 'bundle-id'. It's used to find the running global instance"))
        }
        result[id] = def
    }
    return result
}

func parseRawProjects(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> OrderedJson.JsonArray {
    guard let array = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    return array
}

private func parseRawProjectAppRefs(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [RawProjectAppRef] {
    guard let array = raw.asArrayOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace))
        return []
    }
    var result: [RawProjectAppRef] = []
    for (index, elem) in array.enumerated() {
        let backtrace = backtrace + .index(index)
        switch elem {
            case .string(let appId):
                result.append(RawProjectAppRef(index: index, appId: appId))
            case .dict:
                let ref = parseTable(elem, RawProjectAppRef(index: index), rawProjectAppRefParser, backtrace, &c)
                if ref.appId == nil {
                    c.errors.append(.init(backtrace, "'app' is mandatory key"))
                } else {
                    result.append(ref)
                }
            default:
                c.errors.append(expectedActualTypeDiagnostic(expected: [.string, .table], actual: elem.tomlType, backtrace))
        }
    }
    return result
}

private func parseBundleId(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String?> {
    parseString(raw, backtrace).flatMap { bundleId in
        !bundleId.isEmpty && !bundleId.contains(where: { $0.isWhitespace })
            ? .success(bundleId)
            : .failure(.init(backtrace, "Invalid bundle ID '\(bundleId)'. It must be non-empty and must not contain whitespaces"))
    }
}

private func parseProjectArrayOfStrings(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[String]> {
    parseTomlArray(raw, backtrace)
        .flatMap { arr in arr.enumerated().mapAllOrFailure { (index, elem) in parseString(elem, backtrace + .index(index)) } }
}

func parseInactiveProjectActivationPolicy(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<InactiveProjectActivationPolicy> {
    parseString(raw, backtrace).flatMap {
        parseEnum($0, InactiveProjectActivationPolicy.self).toParsedConfig(backtrace)
    }
}

/// Must be called after `project-apps` are parsed
func resolveProjects(
    _ rawProjects: OrderedJson.JsonArray,
    _ appDefs: [String: ProjectAppDef],
    _ backtrace: ConfigBacktrace,
    _ c: inout ConfigParserContext,
) -> [Project] {
    var result: [Project] = []
    var projectNames: Set<String> = []
    var wholeAppReferences: [String: [String]] = [:] // appId -> project names
    var appIdsWithInvalidMatcher: Set<String> = []
    for (index, raw) in rawProjects.enumerated() {
        let backtrace = backtrace + .index(index)
        let rawProject = parseTable(raw, RawProject(), rawProjectParser, backtrace, &c)
        guard let rawName = rawProject.name else {
            c.errors.append(.init(backtrace, "'name' is mandatory key"))
            continue
        }
        guard let name = parseProjectName(rawName).toParsedConfig(backtrace + .key("name")).getOrNil(appendErrorTo: &c.errors) else { continue }
        if !projectNames.insert(name).inserted {
            c.errors.append(.init(backtrace + .key("name"), "Duplicated project name '\(name)'"))
            continue
        }
        var apps: [ProjectApp] = []
        var appIds: Set<String> = []
        for ref in rawProject.apps {
            let backtrace = backtrace + .key("apps") + .index(ref.index)
            let appId = ref.appId.orDie()
            guard let def = appDefs[appId] else {
                c.errors.append(.init(backtrace, "Unknown project app '\(appId)'. It must be declared in [project-apps.\(appId)]"))
                continue
            }
            if !appIds.insert(appId).inserted {
                c.errors.append(.init(backtrace, "App '\(appId)' is referenced more than once in project '\(name)'"))
                continue
            }
            if !def.isShared {
                wholeAppReferences[appId, default: []].append(name)
            }
            let rawIf = def.rawIf.orDie().replacingOccurrences(of: projectPlaceholder, with: name)
            let ifBacktrace = ConfigBacktrace.rootKey(projectAppsConfigRootKey) + .key(appId) + .key("if")
            let matcher: Shell<any Command>
            switch parseProjectAppMatcher(rawIf) {
                case .success(let it): matcher = it
                case .failure(let msg):
                    // Report the error only once per app definition
                    if appIdsWithInvalidMatcher.insert(appId).inserted { c.errors.append(.init(ifBacktrace, msg)) }
                    continue
            }
            if !ref.open.isEmpty && def.launch?.contains(openPlaceholder) != true {
                c.errors.append(.init(backtrace + .key("open"), "'open' requires \(openPlaceholder) placeholder in 'launch' of [project-apps.\(appId)]"))
            }
            apps.append(ProjectApp(
                appId: appId,
                isShared: def.isShared,
                matcher: matcher,
                launch: def.launch?.replacingOccurrences(of: projectPlaceholder, with: name),
                autostart: ref.autostart,
                open: ref.open,
            ))
        }
        let linkBrowser = rawProject.linkBrowser ?? (appIds.contains("chrome") ? "chrome" : nil)
        if let linkBrowser, appDefs[linkBrowser] == nil {
            c.errors.append(.init(backtrace + .key("link-browser"), "Unknown project app '\(linkBrowser)'"))
        }
        result.append(Project(name: name, apps: apps, linkBrowser: linkBrowser))
    }
    for (appId, projects) in wholeAppReferences.sorted(by: { $0.key < $1.key }) where projects.count > 1 {
        let msg = "Whole-app definition '\(appId)' (its 'if' doesn't contain \(projectPlaceholder)) " +
            "is referenced by several projects: \(projects.joined(separator: ", ")). " +
            "A whole-app definition can be referenced only by a single project"
        c.errors.append(.init(.rootKey(projectAppsConfigRootKey) + .key(appId), msg))
    }
    return result
}

/// Project app matchers are evaluated against an app (process), not against a window.
/// That's why only a subset of commands is allowed
func parseProjectAppMatcher(_ raw: String) -> ResOrStr<Shell<any Command>> {
    parseCommand(raw, allowExecAndForget: false, allowEval: false).toResult().flatMap { shell in
        if case .empty = shell { return .failure("The matcher must not be empty") }
        if let error = validateProjectAppMatcher(shell) { return .failure(error) }
        return .success(shell)
    }
}

private func validateProjectAppMatcher(_ shell: Shell<any Command>) -> String? {
    switch shell {
        case .pipe: return "Pipes are not allowed in project app matchers"
        case .and(let it), .or(let it), .seq(let it): return it.lazy.compactMap(validateProjectAppMatcher).first
        case .empty: return nil
        case .cmd(let cmd):
            let lhs: FormatVar
            switch cmd {
                case is TrueCommand, is FalseCommand: return nil
                case let cmd as TestCommand: lhs = cmd.args.lhs.val
                case let cmd as TestNotCommand: lhs = cmd.args.testArgs.lhs.val
                default: return "Only 'test', 'test-not', 'true' and 'false' commands are allowed in project app matchers. Got: '\(cmd.info.kind.rawValue)'"
            }
            return switch lhs {
                case .app(.appProject): "%{app-project} is not allowed in project app matchers"
                case .app: nil
                default: "Only %{app-*} interpolation variables are allowed in project app matchers. Got: %{\(lhs.rawValue)}"
            }
    }
}

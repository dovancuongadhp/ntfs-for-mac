/// Interprets the `mount(8)`-style arguments FSKit passes to `loadResource`.
public enum MountOptions {
    /// Whether the arguments ask for a read-only mount, e.g. `-r`, `--rdonly`
    /// or `-o rdonly` / `-o ro` (possibly inside a comma-separated list).
    public static func requestsReadOnly(_ arguments: [String]) -> Bool {
        var expectsOptionList = false
        for argument in arguments {
            if expectsOptionList {
                expectsOptionList = false
                if containsReadOnly(optionList: argument) { return true }
                continue
            }
            switch argument {
            case "-r", "--rdonly", "--readonly", "rdonly", "ro":
                return true
            case "-o":
                expectsOptionList = true
            default:
                if argument.hasPrefix("-o"), containsReadOnly(optionList: String(argument.dropFirst(2))) {
                    return true
                }
            }
        }
        return false
    }

    private static func containsReadOnly(optionList: String) -> Bool {
        var readOnly = false
        for option in optionList.split(separator: ",") {
            switch option.filter({ $0 != " " }) {
            case "rdonly", "ro": readOnly = true
            case "rw", "nordonly": readOnly = false
            default: break
            }
        }
        return readOnly
    }
}

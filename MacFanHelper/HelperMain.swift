import Foundation

@main
enum MacFanHelperMain {
    static func main() {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("MacFanHelper must run as root.\n".utf8))
            exit(EXIT_FAILURE)
        }

        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--check") {
            runReadOnlyCheck()
            return
        }
        if arguments.contains("--restore-system") {
            restoreSystemOnce()
            return
        }

        do {
            let configuration = try HelperConfiguration.load()
            MacFanHelperService(configuration: configuration).run()
        } catch {
            FileHandle.standardError.write(Data("MacFanHelper failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func runReadOnlyCheck() {
        do {
            let hardware = try SMCFanHardwareController()
            let states = try hardware.states()
            guard states.allSatisfy({ !$0.isManual }) else {
                throw HelperSMCError.restoreNotConfirmed
            }
            let temperature = try hardware.hottestTemperature()
            let payload: [String: Any] = [
                "ok": true,
                "hottestCelsius": temperature,
                "fans": states.map { state in
                    [
                        "id": state.limit.id,
                        "actualRPM": state.actualRPM,
                        "minimumRPM": state.limit.minimumRPM,
                        "maximumRPM": state.limit.maximumRPM,
                        "manual": state.isManual
                    ]
                }
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("MacFan check failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func restoreSystemOnce() {
        guard !MacFanHelperConstants.competingControllerPaths.contains(where: FileManager.default.fileExists) else {
            FileHandle.standardError.write(Data("Refusing to write while another fan helper is installed.\n".utf8))
            exit(EXIT_FAILURE)
        }
        do {
            let hardware = try SMCFanHardwareController()
            guard hardware.restoreSystem() else { throw HelperSMCError.restoreNotConfirmed }
            FileHandle.standardOutput.write(Data("macOS Auto fan control confirmed.\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Restore failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}

import Foundation
@main struct Canary {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[2].hasPrefix("/tmp/") else { fatalError("Usage: canary <source-home> <scratch-database-under-tmp>") }
        let collector = try SessionUsageCollector(home:URL(fileURLWithPath:args[1]),database:URL(fileURLWithPath:args[2]))
        let report = try collector.refresh()
        let data = try JSONEncoder().encode(report)
        FileHandle.standardOutput.write(data)
    }
}

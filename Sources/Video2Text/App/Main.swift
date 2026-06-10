import Foundation

@main
enum Main {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if let idx = args.firstIndex(of: "--smoke") {
            args.remove(at: idx)
            await SmokeTest.run(arguments: args)
        } else {
            Video2TextApp.main()
        }
    }
}

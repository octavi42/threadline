import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"
let rest = Array(args.dropFirst())

switch cmd {
case "daemon":
    Daemon.run()
case "toggle", "show", "hide", "quit", "status", "refresh":
    CLI.send(cmd, args: rest)
case "install":
    LaunchAgent.install()
case "uninstall":
    LaunchAgent.uninstall()
case "help", "-h", "--help":
    printUsage()
default:
    FileHandle.standardError.write(Data("unknown command: \(cmd)\n".utf8))
    printUsage()
    exit(2)
}

func printUsage() {
    print("""
    threadline-overlay — floating AI-session HUD

    USAGE:
      threadline-overlay <command>

    COMMANDS:
      toggle       show/hide the panel
      show         show panel once; any keypress dismisses it
      hide         hide the panel
      refresh      force re-scan of session sources
      status       print whether the daemon is running
      daemon       run the panel daemon (foreground)
      install      install LaunchAgent so the daemon starts at login
      uninstall    remove the LaunchAgent
    """)
}

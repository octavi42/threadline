import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"
let rest = Array(args.dropFirst())

switch cmd {
case "daemon":
    Daemon.run()
case "toggle", "show", "hide", "quit", "status", "refresh", "list":
    CLI.send(cmd, args: rest)
case "touch":
    CLI.touch(args: rest)
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
      toggle       enable/disable follow mode
      show         peek for a few seconds
      hide         disable follow + hide
      refresh      force re-scan of session sources
      status       print daemon pid, panel frame, current anchor
      touch        register a shell's cwd with the daemon
                   (use --cwd PATH --pid PID; called from the shell prompt)
      daemon       run the panel daemon (foreground)
      install      install LaunchAgent + shell hook
      uninstall    remove LaunchAgent + shell hook
    """)
}

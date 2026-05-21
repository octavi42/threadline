import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"
let rest = Array(args.dropFirst())

switch cmd {
case "daemon":
    Daemon.run()
case "toggle", "show", "hide", "quit", "status", "refresh", "list", "snapshots", "jump", "focus", "focus-debug":
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
    threadline-overlay — AI-session app

    USAGE:
      threadline-overlay <command>

    COMMANDS:
      toggle       show or hide the Threadline window
      show         show the Threadline window
      hide         hide the Threadline window
      refresh      force re-scan of session sources
      focus        select the frontmost terminal's project, or --cwd PATH
      focus-debug  print focused-terminal matching diagnostics
      jump         focus the selected agent's terminal/editor
      status       print daemon pid, window frame, and agent count
      snapshots    dump session rows (--json for E2E automation)
      touch        register a shell's cwd with the daemon
                   (use --cwd PATH --pid PID; called from the shell prompt)
      daemon       run the app daemon (foreground)
      install      install LaunchAgent + shell hook
      uninstall    remove LaunchAgent + shell hook
    """)
}

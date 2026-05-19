# Security Policy

## Supported Versions

Security fixes target the latest public release and the `main` branch.

## Reporting a Vulnerability

Please do not open a public issue for a suspected vulnerability.

Report security concerns by emailing the maintainer listed on the GitHub profile for `octavi42`, or by opening a private security advisory on GitHub if available.

Include:

- A short description of the issue.
- Steps to reproduce or a proof of concept.
- The affected version or commit.
- Any relevant logs with secrets and private prompts redacted.

## Scope

Useful reports include issues such as:

- Accidental exposure of local session data.
- Unsafe handling of shell hooks, LaunchAgents, or installer paths.
- Command execution risks.
- Insecure update, release, or install behavior.

Threadline is a local macOS tool. It should not upload session content or telemetry. If you observe network behavior outside documented local or optional provider calls, please report it.

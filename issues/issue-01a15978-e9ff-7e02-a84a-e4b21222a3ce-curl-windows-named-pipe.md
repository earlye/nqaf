# curl fork that speaks HTTP over a Windows named pipe

## Context

Requested from the firkin session (`de3fbd7b44c1-agent-cli-first-slice-b4`) on behalf of the user.

- firkin lives in `firkin-media/firkin`. Its per-user resident process, `firkin-agent`, is controlled by the `firkin` CLI over a private IPC channel (ADR 0002 in that repo).
- The first slice uses JSON-lines request/response over a local socket via the `interprocess` crate. That is a Unix socket on Linux/macOS and a named pipe on Windows. Every connection opens with a `hello` message that carries the protocol version.
- The eventual plan is to switch to HTTP over that same local endpoint on all three platforms, Docker-style. The agent can then be debugged with `curl --unix-socket` on Linux/macOS.
- On Windows there is a gap: curl cannot connect to a named pipe, so there is no equivalent way to debug the agent there.

## Need

A curl that can send HTTP over a Windows named pipe, for example a `--named-pipe \\.\pipe\<name>` option analogous to `--unix-socket`. This would restore the debugging story on Windows before or when firkin switches to HTTP over the pipe.

The preferred route is an upstream contribution to curl, if that turns out to be feasible. Otherwise, a fork carried by nqaf.

Not urgent. firkin adoption is expected to be slow, so this is groundwork for the eventual switch.

## Next steps

- Before forking, check whether upstream curl, an existing fork, or another tool already covers HTTP over a Windows named pipe.
- If nothing does, decide between an upstream contribution and an nqaf-carried curl fork.

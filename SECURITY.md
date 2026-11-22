# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| `0.1.x` | Yes |

## Security Model (Free Edition)

`robot_stream` provides baseline LAN security enabled by default:

- **Per-robot bearer token:** Generated automatically on first launch (`~/.config/robot_stream/token`, mode `0600`) and verified by `rosbridge_guard` (`:9091`) and MediaMTX WHEP (`:8889`). Missing or invalid tokens return HTTP `401` and stop client reconnection (`LinkRejected` / `VideoFailed`).
- **Command audit log:** `rosbridge_guard` writes rotating JSON-line audit entries (`~/robot_stream/audit.log`) for connections, rejections, action goals, cancellations, service calls, command publishes, and teleop sessions.
- **Optional TLS + certificate pinning:** Generate a self-signed certificate with `robot_node/scripts/make_cert.sh`, launch with `tls:=true`, and pin the SHA-256 fingerprint on the client via `pinnedHttpClient` and `WhepSignaling.pinned`.
- **Deadman safety:** `deadman_node` tracks the active controlling session's heartbeat and cancels navigation goals / stops velocity commands if connectivity drops.

## Known Limitations

Operators must account for the following gaps in the Free edition:

1. **Plaintext tokens without TLS:** With `tls:=false`, bearer tokens are sent in cleartext HTTP/WebSocket headers over Wi-Fi. Anyone sniffing the local network can capture the token. Enable `tls:=true` and pin the certificate fingerprint whenever using shared or untrusted Wi-Fi.
2. **Open ROS 2 DDS on the LAN:** `rosbridge_guard` only guards the WebSocket entry point. Other ROS 2 machines on the same LAN can still publish directly to robot topics over DDS unless `ROS_LOCALHOST_ONLY=1` or SROS2 is configured on the robot.
3. **Vendor rosbridge port (`:9090`):** Robots whose built-in software launches `rosbridge_server` bound to `0.0.0.0:9090` (for example, Wheeltec R550's AIUI launch) leave that port unauthenticated until the vendor launch is changed to bind `127.0.0.1`.
4. **No direct internet exposure:** Never port-forward `:8889`, `:8189`, or `:9091` to the public internet. Use a private VPN (such as WireGuard/Tailscale) or an authenticated relay/TURN service for remote operation.
5. **Physical robot safety:** Software deadman timers and stop commands cannot replace a hardware emergency stop (E-stop). Always maintain physical supervision when moving a robot.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, report vulnerabilities privately via GitHub Security Advisories on [`robot-stream/robot_stream`](https://github.com/robot-stream/robot_stream/security/advisories/new) with:

- Affected package(s) and version
- Steps to reproduce or proof of concept
- Impact assessment and suggested remediation (if any)

We aim to acknowledge reports within 7 days.

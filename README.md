# Network Refresh

A Windows batch script that clears every name and address cache and renews the
DHCP leases, then tells you whether it helped.

**Nothing in it requires a reboot.** Every command takes effect the moment it
runs. There is no shutdown or restart anywhere in the file.

This is the standalone copy of the `net-reset-lite.bat` that
[winGG10&11](https://github.com/su-Alexis/winGG10-11) writes to the Desktop. The two
are kept byte-identical: if they ever differ, the copy embedded in winGG10&11 is the
current one. winGG10&11 only writes this file; it never runs it.

---

## Usage

```bat
net-reset-lite.bat /dryrun     print every command, change nothing
net-reset-lite.bat             run it (asks before it starts)
net-reset-lite.bat /verify     connectivity checks only
net-reset-lite.bat /?          list every option
```

| Flag | Effect |
|---|---|
| `/dryrun` | Print every command without running anything. |
| `/verify` | Connectivity checks only. Changes nothing, needs no admin. |
| `/y` | Skip the confirmation prompt. |
| `/force` | Run even from a remote session. |
| `/adapter` | Also bounce the physical adapters — a harder reset of the link itself, still no reboot. Virtual adapters are left alone on purpose. |
| `/proxy` | Also clear the system-wide WinHTTP proxy. Off by default. |

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Network is up |
| `1` | Cancelled at the confirmation prompt |
| `2` | Refused because it was started from a remote session |
| `3` | Still down afterwards — escalate |
| `64` | Bad argument |

## What it does

Thirteen steps, in this order:

1. Flush the DNS resolver cache
2. Purge the NetBIOS name cache
3. Release and refresh NetBIOS names
4. Flush the ARP cache
5. Clear the IPv4 destination cache
6. Clear the IPv6 destination cache
7. Clear the IPv6 neighbour cache
8. Release the IPv4 DHCP leases
9. Release the IPv6 DHCP leases
10. Request fresh IPv4 leases
11. Request fresh IPv6 leases
12. Re-register this machine in DNS
13. Flush the DNS cache again, against the new lease

The second DNS flush is deliberate: the first one clears whatever was cached
against the old lease, and the last one clears anything resolved during the
renew.

## What it deliberately leaves out

These four need a reboot to apply, so they are not here:

```
netsh int ip reset          netsh int ipv6 reset
netsh winsock reset         netsh advfirewall reset
```

Because the stack is never reset, statically configured DNS servers are never
wiped, so unlike the heavier tool this one needs no save-and-restore dance for
them. It just records them in the log.

If this script does not fix the problem,
[Network Stack Reset](https://github.com/su-Alexis/Network-Stack-Reset)
(`net-reset-reboot.bat`) is the next step
up — it runs those four and reboots. This script says so at the end when its
checks still report the network as down.

## It refuses to run over Remote Desktop

It releases the IP address, which severs a remote session. It detects that and
stops, unless you pass `/force`.

## Before and after in one run

It checks connectivity before and after, in the same run, and gives a verdict:

- **up** — no reboot needed, you are done
- **still down** — it names the heavier tool and exits `3`

Both sets of checks go into the log so you can compare them.

## What it writes

A timestamped log, `netlite_<stamp>.log`, in `netreset-logs\` beside the script,
falling back to `%TEMP%` if that is not writable. It shares that folder with Network Stack Reset but uses
its own filename prefix, so the two never collide.

## Design notes

- Nothing here deletes a file or changes a persistent setting. Every step either
  clears a cache or re-requests a lease.
- Every command is a standard, documented Microsoft tool: `ipconfig`, `netsh`,
  `nbtstat`, `arp`. Nothing is downloaded.
- `/dryrun` and `/verify` cannot change anything, so neither needs admin rights.
- `/adapter` leaves virtual adapters alone deliberately, so hypervisor networking
  is not disturbed.
- The confirmation prompt re-asks quietly on a mistyped key rather than beeping,
  and gives up after ten unusable answers so the script cannot hang when another
  script drives it.

## Caveats

- You lose connectivity for a few seconds during the release/renew.
- `/adapter` takes the link down and back up, which is longer and more disruptive
  than the default.
- If a renew fails you are briefly left without an address; `ipconfig /renew`
  gets it back.

## Related tools

- [winGG10&11](https://github.com/su-Alexis/winGG10-11): the Windows setup script
  that deploys this and the other two tools.
- [Windows Cleanup](https://github.com/su-Alexis/Windows-Cleanup)
  (`cleanup_main.bat`): scan-first temp, cache and memory cleanup.
- [Network Stack Reset](https://github.com/su-Alexis/Network-Stack-Reset)
  (`net-reset-reboot.bat`): full TCP/IP and Winsock reset, needs a reboot.

## Requirements

Windows 10 or 11. Administrator rights for the full run (it elevates itself);
`/dryrun` and `/verify` need none. No dependencies.

## License

MIT - see [LICENSE](LICENSE).

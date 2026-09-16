---
name: sudoers-dropin
description: Let a Mac app run one specific root command without asking for a password every time, by installing a narrow /etc/sudoers.d rule once. Use instead of writing a privileged helper.
---

# sudoers drop-in (visudo + install)

**Solved in Dex:** `pmset disablesleep` needs root. Instead of a password prompt on every toggle, or a heavy SMJobBless helper, the app installs a one-line rule on first use.

**When:** a small app needs 1–2 fixed root commands. Not for arbitrary commands.

## Example
```sh
# rule file (exact arguments only)
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1

# validate, then install with the correct owner and permissions (as root)
/usr/sbin/visudo -cf /tmp/dex-sudoers && /usr/bin/install -m 440 -o root -g wheel /tmp/dex-sudoers /etc/sudoers.d/dex

# use from the app (never prompts)
/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1
```
Pattern in code: `trySudo() || (installRule() && trySudo())`

## Critical considerations
- **Always `visudo -cf` first.** A broken sudoers file can lock `sudo` out completely.
- Use full paths and exact arguments. Never wildcards (`pmset *` would allow any pmset change).
- File must be `0440 root:wheel`. The file name must not contain `.` or `~`, or sudo ignores it.
- `%admin` only covers admin users. Standard accounts can't install it anyway.
- This is a security-sensitive change. Tell the user and document removal: `sudo rm /etc/sudoers.d/dex`.

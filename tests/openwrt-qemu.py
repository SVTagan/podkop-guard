#!/usr/bin/env python3
"""Boot real OpenWrt 25.12.x under QEMU and test apk and procd via serial.

No interaction with a router, real UCI or public services; ephemeral QEMU only.
"""
import re
import sys
import time

import pexpect

image = sys.argv[1]
child = pexpect.spawn(
    "qemu-system-x86_64",
    [
        "-m", "384", "-smp", "2", "-nographic", "-monitor", "none",
        "-drive", f"file={image},format=raw,if=virtio,snapshot=on",
        # Read-only ext4 fixture bundle made from this exact GitHub checkout.
        "-drive", "file=openwrt-test-bundle.img,format=raw,if=virtio,readonly=on",
        "-nic", "user,model=virtio",
        "-no-reboot",
    ],
    encoding="utf-8", timeout=180, maxread=65536
)
child.logfile = sys.stdout
prompt = re.compile(r"root@OpenWrt:[^\r\n]*#\s*")
try:
    deadline = time.monotonic() + 165
    while time.monotonic() < deadline:
        match = child.expect(
            [prompt, r"Please press Enter to activate this console",
             r"OpenWrt login:", pexpect.TIMEOUT, pexpect.EOF],
            timeout=min(45, max(1, int(deadline - time.monotonic()))),
        )
        if match == 0:
            break
        if match in (1, 2, 3):
            child.sendline("" if match in (1, 3) else "root")
        else:
            raise RuntimeError("OpenWrt QEMU closed during boot")
    else:
        raise RuntimeError("OpenWrt serial login timed out")

    serial = 0

    def run(cmd, timeout=50):
        global serial
        serial += 1
        token = f"__PGVM_{serial:03d}__"
        child.sendline(f"{cmd}; x=$?; printf '\\n{token}=%s\\n' \"$x\"")
        child.expect(re.escape(token) + r"=(\d+)", timeout=timeout)
        rc = int(child.match.group(1))
        child.expect(prompt, timeout=30)
        if rc:
            raise RuntimeError(f"VM command returned {rc}: {cmd}")
        return rc

    run("grep -q '25.12.6' /etc/openwrt_release")
    run("command -v apk && apk --version")
    run("apk info -e procd")
    run("apk info -e busybox")
    run("command -v ubus && command -v uci")
    print("PASS: real OpenWrt 25.12.6 apk package database", flush=True)

    init_script = """#!/bin/sh /etc/rc.common
START=98
USE_PROCD=1
start_service() {
    procd_open_instance first
    procd_set_param command /bin/sleep 120
    procd_set_param respawn 3600 5 5
    procd_close_instance
    procd_open_instance second
    procd_set_param command /bin/sleep 120
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
"""
    # Minimal stock BusyBox has no base64 applet. Use short serial lines
    # instead of a long command that may overflow the tty input buffer.
    child.sendline("cat > /etc/init.d/pg-vm-test <<'PG_VM_INIT_EOF'")
    for line in init_script.rstrip("\n").splitlines():
        child.sendline(line)
    child.sendline("PG_VM_INIT_EOF")
    child.expect(prompt, timeout=30)
    run("chmod +x /etc/init.d/pg-vm-test")
    run("/etc/init.d/pg-vm-test start")
    run("""ubus call service list '{"name":"pg-vm-test"}' | grep -q '"first"'""")
    run("""ubus call service list '{"name":"pg-vm-test"}' | grep -q '"second"'""")
    print("PASS: real procd supports independent named instances", flush=True)
    run("/etc/init.d/pg-vm-test stop")
    run("""! ubus call service list '{"name":"pg-vm-test"}' | grep -q '"first"'""")
    print("PASS: real procd stops both named instances", flush=True)
    print("QEMU_25_12_PASS", flush=True)

    # A disposable guest is allowed to update its own /usr/bin and init.d.
    # The host machine and user's AX6000 have no connection to these files.
    run("mkdir -p /mnt/pg-bundle")
    run("mount -t ext4 -o ro /dev/vdb /mnt/pg-bundle")
    run("test -r /mnt/pg-bundle/openwrt-installer-e2e.sh")
    run("test -r /mnt/pg-bundle/install.sh")
    run("test -r /mnt/pg-bundle/podkop-guard.init")
    run("sh /mnt/pg-bundle/openwrt-installer-e2e.sh", timeout=240)
    print("QEMU_INSTALLER_E2E_PASS", flush=True)
    run("test -r /mnt/pg-bundle/podkop-guard")
    run("test -r /mnt/pg-bundle/openwrt-real-worker-e2e.sh")
    run("sh /mnt/pg-bundle/openwrt-real-worker-e2e.sh", timeout=330)
    print("QEMU_REAL_WORKER_E2E_PASS", flush=True)
finally:
    child.close(force=True)

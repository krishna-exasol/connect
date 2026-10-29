"""Give Exasol Personal's language containers the deployment's DNS.

    personal-slc-dns.py [--podman PODMAN] FLAVOR [FLAVOR ...]

A language container (SLC) is its own filesystem, and the official ones ship
etc/resolv.conf and etc/hosts EMPTY. The database mounts the deployment's real
files into every UDF sandbox at /conf, but a UDF reads /etc: Java code in the
database can reach any IP address and resolve no name, so a virtual schema
adapter cannot connect to a remote source by hostname. Every database start
rebuilds the container from its image, so this runs after every start.

This is the host-Podman route (Linux, WSL, Windows), where the database
container belongs to the Podman this machine talks to. On macOS the container
lives in the launcher's VM and runtime-personal.sh feeds the same logic, as a
POSIX sh script, to `exasol shell container`. Python because Windows has no sh
and Windows PowerShell 5.1 cannot pipe binary data between programs: the two
symlinks are written straight into an in-memory tar stream (no symlink
privileges needed on the host) and handed to `podman cp -`.

Only a file that is still the shipped EMPTY one is replaced, so a Personal
release that fixes this upstream turns the step into a no-op.

Prints one "EXAKIT_SLC_DNS <flavor> repaired|ok|absent|failed" line per flavor
(or "EXAKIT_SLC_DNS - nocontainer"). Exit 0 unless a repair failed.
"""

import argparse
import io
import subprocess
import sys
import tarfile

LINKS = (("resolv.conf", "/conf/resolv.conf"), ("hosts", "/conf/hosts"))


def container(podman):
    out = subprocess.run([podman, "ps", "--filter", "name=exasol-db-", "--format", "{{.Names}}"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
    names = out.stdout.decode("utf-8", "replace").split()
    return names[0] if names else ""


def state(podman, ctr, flavor):
    """absent | ok | empty: what etc/resolv.conf is in that container."""
    done = subprocess.run([podman, "cp", "%s:/exa/slc/%s/etc" % (ctr, flavor), "-"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
    if done.returncode != 0 or not done.stdout:
        return "absent"
    try:
        with tarfile.open(fileobj=io.BytesIO(done.stdout)) as archive:
            for member in archive.getmembers():
                if member.name.rstrip("/").endswith("etc/resolv.conf"):
                    if member.issym() or member.size > 0:
                        return "ok"
                    return "empty"
    except tarfile.TarError:
        return "absent"
    return "absent"


def links_tar():
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, target in LINKS:
            info = tarfile.TarInfo(name)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            info.mode = 0o777
            archive.addfile(info)
    return buffer.getvalue()


def main(argv=None):
    parser = argparse.ArgumentParser(prog="personal-slc-dns.py")
    parser.add_argument("--podman", default="podman")
    parser.add_argument("flavors", nargs="+")
    args = parser.parse_args(argv)
    try:
        ctr = container(args.podman)
    except (OSError, subprocess.SubprocessError):
        ctr = ""
    if not ctr:
        print("EXAKIT_SLC_DNS - nocontainer")
        return 0
    failed = False
    for flavor in args.flavors:
        try:
            found = state(args.podman, ctr, flavor)
            if found != "empty":
                print("EXAKIT_SLC_DNS %s %s" % (flavor, found))
                continue
            done = subprocess.run([args.podman, "cp", "-", "%s:/exa/slc/%s/etc/" % (ctr, flavor)],
                                  input=links_tar(), stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=120)
            ok = done.returncode == 0 and state(args.podman, ctr, flavor) == "ok"
        except (OSError, subprocess.SubprocessError):
            ok = False
        print("EXAKIT_SLC_DNS %s %s" % (flavor, "repaired" if ok else "failed"))
        failed = failed or not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

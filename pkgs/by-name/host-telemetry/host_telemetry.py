"""Convert ZFS and SMART status into node_exporter textfile metrics.

Both commands share one freshness rule: the output file is replaced only
after a complete, successful run. A failed or stuck run leaves the previous
file and its modification time untouched, so the collector sees stale data
through node_textfile_mtime_seconds instead of a fresh-looking file.

Exit codes: 0 on success; COLLECTION_FAILED (75) when collection failed and
the previous file was kept. The systemd units treat 75 as success so a
telemetry failure never marks a unit failed or fails host activation; the
stale-file alerts report it instead.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

COLLECTION_FAILED = 75
COMMAND_TIMEOUT = 60


class CollectionError(Exception):
    pass


def escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def sample(name, labels, value):
    rendered = ",".join(f'{key}="{escape(labels[key])}"' for key in sorted(labels))
    return f"{name}{{{rendered}}} {value}"


def as_int(value):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    raise CollectionError(f"expected an integer, got {value!r}")


def write_atomically(path, lines):
    directory = os.path.dirname(os.path.abspath(path))
    handle, temporary = tempfile.mkstemp(prefix=".tmp-", suffix=".prom", dir=directory)
    try:
        with os.fdopen(handle, "w") as output:
            output.write("\n".join(lines) + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def parse_disks(entries):
    disks = {}
    for entry in entries:
        name, separator, path = entry.partition("=")
        if not separator or not name or not path:
            raise SystemExit(f"--disk takes NAME=PATH, got {entry!r}")
        if name in disks:
            raise SystemExit(f"disk {name} is declared twice")
        disks[name] = path
    return disks


def block_device(path):
    """Resolve a device path to its whole-disk node, dropping a partition suffix."""
    resolved = os.path.realpath(path)
    directory, base = os.path.split(resolved)
    match = re.fullmatch(r"(nvme[0-9]+n[0-9]+)p[0-9]+", base)
    if match:
        return os.path.join(directory, match.group(1))
    match = re.fullmatch(r"((?:sd|vd|xvd|hd)[a-z]+)[0-9]+", base)
    if match:
        return os.path.join(directory, match.group(1))
    return resolved


# ---------------------------------------------------------------------------
# ZFS


ZPOOL_ERROR_KINDS = ("read", "write", "checksum")


def leaf_vdevs(vdev):
    children = vdev.get("vdevs") or {}
    if not children:
        yield vdev
        return
    for child in children.values():
        yield from leaf_vdevs(child)


def zpool_metrics(document, disks):
    pools = document.get("pools")
    if not isinstance(pools, dict):
        raise CollectionError("zpool status JSON has no pools object")
    # A leaf device is labelled with its declared disk name. Device paths in
    # zpool output often embed serial numbers, so an undeclared device is
    # labelled by its GUID rather than its path.
    declared = {block_device(path): name for name, path in disks.items()}
    lines = []
    for pool_name in sorted(pools):
        pool = pools[pool_name]
        labels = {"pool": pool_name}
        state = pool.get("state")
        if not isinstance(state, str):
            raise CollectionError(f"pool {pool_name} has no state")
        lines.append(sample("homelab_zpool_present", labels, 1))
        lines.append(sample("homelab_zpool_healthy", labels, 1 if state == "ONLINE" else 0))
        lines.append(sample("homelab_zpool_state", {**labels, "state": state}, 1))
        lines.append(sample("homelab_zpool_data_errors", labels, as_int(pool.get("error_count", "0"))))

        scan = pool.get("scan_stats") or {}
        if scan.get("function") == "SCRUB":
            lines.append(sample("homelab_zpool_scrub_active", labels, 1 if scan.get("state") == "SCANNING" else 0))
            if scan.get("state") == "FINISHED":
                lines.append(sample("homelab_zpool_scrub_end_time_seconds", labels, as_int(scan.get("end_time"))))
                lines.append(sample("homelab_zpool_scrub_errors", labels, as_int(scan.get("errors", "0"))))
        elif not scan:
            # Never scrubbed: report the epoch so the overdue rule fires.
            lines.append(sample("homelab_zpool_scrub_active", labels, 0))
            lines.append(sample("homelab_zpool_scrub_end_time_seconds", labels, 0))

        roots = pool.get("vdevs") or {}
        for root in roots.values():
            for leaf in leaf_vdevs(root):
                path = leaf.get("path")
                name = declared.get(block_device(path)) if path else None
                vdev = name if name is not None else "guid-" + str(leaf.get("guid", "unknown"))
                vdev_labels = {**labels, "vdev": vdev}
                lines.append(sample("homelab_zpool_vdev_healthy", vdev_labels, 1 if leaf.get("state") == "ONLINE" else 0))
                for kind in ZPOOL_ERROR_KINDS:
                    count = as_int(leaf.get(f"{kind}_errors", "0"))
                    lines.append(sample("homelab_zpool_vdev_errors", {**vdev_labels, "type": kind}, count))
    return lines


def run_zpool(arguments):
    try:
        completed = subprocess.run(
            [arguments.zpool, "status", "-j", "-p"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=COMMAND_TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CollectionError(f"zpool status did not complete: {error}") from error
    if completed.returncode != 0:
        raise CollectionError(f"zpool status exited {completed.returncode}")
    try:
        document = json.loads(completed.stdout)
    except ValueError as error:
        raise CollectionError(f"zpool status printed invalid JSON: {error}") from error
    return zpool_metrics(document, parse_disks(arguments.disk))


# ---------------------------------------------------------------------------
# SMART

# smartctl exit status bits (smartctl(8), "RETURN VALUES").
SMARTCTL_COMMAND_LINE_ERROR = 1 << 0
SMARTCTL_OPEN_FAILED = 1 << 1
SMARTCTL_DISK_FAILING = 1 << 3

ATA_REALLOCATED = 5
ATA_PENDING = 197


def ata_raw(document, attribute_id):
    table = (document.get("ata_smart_attributes") or {}).get("table") or []
    for attribute in table:
        if attribute.get("id") == attribute_id:
            return as_int((attribute.get("raw") or {}).get("value"))
    return None


def smart_disk_metrics(name, path, document, exit_status):
    labels = {"disk": name, "id": os.path.basename(path)}
    status = document.get("smart_status")
    # smartctl reports a device it cannot open as an open failure, and a
    # missing device whose type it cannot guess as a command-line error.
    # Either way this disk was not read; the other disks still are.
    unread = exit_status & (SMARTCTL_OPEN_FAILED | SMARTCTL_COMMAND_LINE_ERROR)
    if unread or not isinstance(status, dict) or "passed" not in status:
        return [sample("homelab_smart_device_up", labels, 0)]
    healthy = bool(status["passed"]) and not exit_status & SMARTCTL_DISK_FAILING
    lines = [
        sample("homelab_smart_device_up", labels, 1),
        sample("homelab_smart_healthy", labels, 1 if healthy else 0),
    ]
    if "scsi_grown_defect_list" in document:
        lines.append(sample("homelab_smart_scsi_grown_defects", labels, as_int(document["scsi_grown_defect_list"])))
    reallocated = ata_raw(document, ATA_REALLOCATED)
    if reallocated is not None:
        lines.append(sample("homelab_smart_ata_reallocated_sectors", labels, reallocated))
    pending = ata_raw(document, ATA_PENDING)
    if pending is not None:
        lines.append(sample("homelab_smart_ata_pending_sectors", labels, pending))
    nvme = document.get("nvme_smart_health_information_log")
    if isinstance(nvme, dict):
        lines.append(sample("homelab_smart_nvme_critical_warning", labels, as_int(nvme.get("critical_warning", 0))))
        lines.append(sample("homelab_smart_nvme_media_errors", labels, as_int(nvme.get("media_errors", 0))))
    temperature = (document.get("temperature") or {}).get("current")
    if isinstance(temperature, int):
        lines.append(sample("homelab_smart_temperature_celsius", labels, temperature))
    return lines


def run_smart(arguments):
    disks = parse_disks(arguments.disk)
    lines = []
    for name in sorted(disks):
        path = disks[name]
        try:
            completed = subprocess.run(
                [arguments.smartctl, "--json=c", "--all", path],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=COMMAND_TIMEOUT,
                check=False,
            )
        except subprocess.TimeoutExpired:
            # One unresponsive disk is that disk's fault, not the run's.
            lines.append(sample("homelab_smart_device_up", {"disk": name, "id": os.path.basename(path)}, 0))
            continue
        except OSError as error:
            raise CollectionError(f"smartctl could not run: {error}") from error
        try:
            document = json.loads(completed.stdout)
        except ValueError as error:
            raise CollectionError(f"smartctl printed invalid JSON for {name}: {error}") from error
        if not isinstance(document, dict) or not isinstance(document.get("smartctl"), dict):
            raise CollectionError(f"smartctl printed no report for {name}")
        exit_status = completed.returncode
        if exit_status < 0:
            raise CollectionError(f"smartctl was killed by signal {-exit_status} for {name}")
        lines.extend(smart_disk_metrics(name, path, document, exit_status))
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    zpool = commands.add_parser("zpool", help="write zpool.prom from `zpool status -j -p`")
    zpool.add_argument("--zpool", required=True)
    zpool.add_argument("--output", required=True)
    zpool.add_argument("--disk", action="append", default=[], help="NAME=PATH of a declared disk")
    smart = commands.add_parser("smart", help="write smart.prom from `smartctl --json --all`")
    smart.add_argument("--smartctl", required=True)
    smart.add_argument("--output", required=True)
    smart.add_argument("--disk", action="append", default=[], help="NAME=PATH of a declared disk")
    arguments = parser.parse_args(argv)
    try:
        lines = run_zpool(arguments) if arguments.command == "zpool" else run_smart(arguments)
        write_atomically(arguments.output, lines)
    except CollectionError as error:
        print(f"{arguments.command} collection failed; keeping the previous file: {error}", file=sys.stderr)
        return COLLECTION_FAILED
    return 0


if __name__ == "__main__":
    sys.exit(main())

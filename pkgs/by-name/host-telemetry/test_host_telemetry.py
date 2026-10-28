"""Unit tests for host_telemetry against recorded `zpool status -j -p` and
`smartctl --json` documents (fixtures/), plus synthetic scan-state variants.
Fake zpool and smartctl commands replay the fixtures, so the real command
handling, exit-status handling and atomic replacement are exercised."""

import json
import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import host_telemetry  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")

FAKE_ZPOOL = """#!{python}
import os, sys
code = int(os.environ.get("FAKE_ZPOOL_EXIT", "0"))
fixture = os.environ.get("FAKE_ZPOOL_FIXTURE")
if fixture:
    sys.stdout.write(open(fixture).read().replace("@DEV@", os.environ["FAKE_DEV"]))
sys.exit(code)
"""

FAKE_SMARTCTL = """#!{python}
import json, os, sys
plan = json.load(open(os.environ["FAKE_SMART_PLAN"]))
path = sys.argv[-1]
entry = plan[path]
if entry.get("broken"):
    sys.stdout.write("not json")
    sys.exit(0)
sys.stdout.write(open(entry["fixture"]).read().replace("@PATH@", path))
sys.exit(entry["exit"])
"""


def read(path):
    with open(path) as handle:
        return handle.read()


def parse(path):
    samples = {}
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name_labels, value = line.rsplit(" ", 1)
            samples[name_labels] = float(value)
    return samples


class Environment:
    def __init__(self):
        self.root = tempfile.TemporaryDirectory()
        self.dir = self.root.name
        self.dev = os.path.join(self.dir, "dev")
        os.makedirs(os.path.join(self.dev, "by-id"))
        os.makedirs(os.path.join(self.dev, "by-path"))
        self.output_dir = os.path.join(self.dir, "textfile")
        os.makedirs(self.output_dir)
        for name, template in (("zpool", FAKE_ZPOOL), ("smartctl", FAKE_SMARTCTL)):
            path = os.path.join(self.dir, name)
            with open(path, "w") as handle:
                handle.write(template.format(python=sys.executable))
            os.chmod(path, 0o755)
        self.zpool = os.path.join(self.dir, "zpool")
        self.smartctl = os.path.join(self.dir, "smartctl")

    def node(self, name):
        path = os.path.join(self.dev, name)
        open(path, "w").close()
        return path

    def link(self, link, target):
        os.symlink(target, os.path.join(self.dev, link))
        return os.path.join(self.dev, link)

    def close(self):
        self.root.cleanup()


class ZpoolTest(unittest.TestCase):
    def setUp(self):
        self.env = Environment()
        env = self.env
        for disk in ("nvme0n1", "nvme0n1p2", "nvme1n1", "nvme1n1p2"):
            env.node(disk)
        # zpool reports by-id partition paths; the declaration names by-path disks.
        env.link("by-id/nvme-EXAMPLE_A-part2", os.path.join(env.dev, "nvme0n1p2"))
        env.link("by-id/nvme-EXAMPLE_B-part2", os.path.join(env.dev, "nvme1n1p2"))
        self.disk_a = env.link("by-path/pci-a-nvme-1", os.path.join(env.dev, "nvme0n1"))
        self.disk_b = env.link("by-path/pci-b-nvme-1", os.path.join(env.dev, "nvme1n1"))
        self.output = os.path.join(env.output_dir, "zpool.prom")
        os.environ["FAKE_DEV"] = env.dev
        os.environ.pop("FAKE_ZPOOL_EXIT", None)

    def tearDown(self):
        self.env.close()

    def run_fixture(self, fixture, exit_code=0):
        if fixture is None:
            os.environ.pop("FAKE_ZPOOL_FIXTURE", None)
        else:
            os.environ["FAKE_ZPOOL_FIXTURE"] = os.path.join(FIXTURES, fixture)
        os.environ["FAKE_ZPOOL_EXIT"] = str(exit_code)
        return host_telemetry.main([
            "zpool", "--zpool", self.env.zpool, "--output", self.output,
            "--disk", f"rpool-a={self.disk_a}", "--disk", f"rpool-b={self.disk_b}",
        ])

    def test_online_pool(self):
        self.assertEqual(self.run_fixture("zpool-online.json"), 0)
        samples = parse(self.output)
        self.assertEqual(samples['homelab_zpool_present{pool="rpool"}'], 1)
        self.assertEqual(samples['homelab_zpool_healthy{pool="rpool"}'], 1)
        self.assertEqual(samples['homelab_zpool_state{pool="rpool",state="ONLINE"}'], 1)
        self.assertEqual(samples['homelab_zpool_scrub_active{pool="rpool"}'], 0)
        self.assertEqual(samples['homelab_zpool_scrub_end_time_seconds{pool="rpool"}'], 1790851949)
        self.assertEqual(samples['homelab_zpool_scrub_errors{pool="rpool"}'], 0)
        for vdev in ("rpool-a", "rpool-b"):
            for kind in ("read", "write", "checksum"):
                self.assertEqual(samples[f'homelab_zpool_vdev_errors{{pool="rpool",type="{kind}",vdev="{vdev}"}}'], 0)
        # Device paths, which can embed serial numbers, never become labels.
        self.assertNotIn("EXAMPLE", read(self.output))

    def test_degraded_pool(self):
        self.assertEqual(self.run_fixture("zpool-degraded.json"), 0)
        samples = parse(self.output)
        self.assertEqual(samples['homelab_zpool_healthy{pool="rpool"}'], 0)
        self.assertEqual(samples['homelab_zpool_state{pool="rpool",state="DEGRADED"}'], 1)
        self.assertEqual(samples['homelab_zpool_vdev_healthy{pool="rpool",vdev="rpool-b"}'], 0)
        self.assertEqual(samples['homelab_zpool_vdev_healthy{pool="rpool",vdev="rpool-a"}'], 1)

    def test_device_errors(self):
        self.assertEqual(self.run_fixture("zpool-device-errors.json"), 0)
        samples = parse(self.output)
        self.assertEqual(samples['homelab_zpool_vdev_errors{pool="rpool",type="read",vdev="rpool-a"}'], 2)
        self.assertEqual(samples['homelab_zpool_vdev_errors{pool="rpool",type="checksum",vdev="rpool-a"}'], 5)
        self.assertEqual(samples['homelab_zpool_vdev_errors{pool="rpool",type="write",vdev="rpool-a"}'], 0)

    def test_scrub_with_errors(self):
        self.assertEqual(self.run_fixture("zpool-scrub-errors.json"), 0)
        samples = parse(self.output)
        self.assertEqual(samples['homelab_zpool_scrub_active{pool="rpool"}'], 0)
        self.assertEqual(samples['homelab_zpool_scrub_end_time_seconds{pool="rpool"}'], 1790851949)
        self.assertEqual(samples['homelab_zpool_scrub_errors{pool="rpool"}'], 3)

    def test_canceled_scrub_and_finished_resilver_report_epoch(self):
        # Synthetic variants retain nonzero scan timestamps and errors; neither
        # is a completed scrub. Publication must also remove previous errors.
        for fixture in ("zpool-scrub-canceled.json", "zpool-resilver-finished.json"):
            with self.subTest(fixture=fixture):
                self.assertEqual(self.run_fixture("zpool-scrub-errors.json"), 0)
                expected = parse(self.output)
                del expected['homelab_zpool_scrub_errors{pool="rpool"}']
                expected['homelab_zpool_scrub_active{pool="rpool"}'] = 0
                expected['homelab_zpool_scrub_end_time_seconds{pool="rpool"}'] = 0
                self.assertEqual(self.run_fixture(fixture), 0)
                # Includes pool health, declared vdev labels and all counters.
                self.assertEqual(parse(self.output), expected)

    def test_running_and_missing_scan_publication(self):
        for function, state in (("SCRUB", "SCANNING"), ("RESILVER", "SCANNING"),
                                (None, None), ("", "")):
            with self.subTest(function=function, state=state):
                self.assertEqual(self.run_fixture("zpool-scrub-errors.json"), 0)
                expected = parse(self.output)
                del expected['homelab_zpool_scrub_errors{pool="rpool"}']
                scrubbing = function == "SCRUB"
                expected['homelab_zpool_scrub_active{pool="rpool"}'] = int(scrubbing)
                if scrubbing:
                    del expected['homelab_zpool_scrub_end_time_seconds{pool="rpool"}']
                else:
                    expected['homelab_zpool_scrub_end_time_seconds{pool="rpool"}'] = 0
                document = json.loads(read(os.path.join(FIXTURES, "zpool-scrub-errors.json")))
                pool = document["pools"]["rpool"]
                if function is None:
                    del pool["scan_stats"]
                elif not function:
                    pool["scan_stats"] = {}
                else:
                    pool["scan_stats"].update(function=function, state=state)
                fixture = os.path.join(self.env.dir, "scan-variant.json")
                with open(fixture, "w") as handle:
                    json.dump(document, handle)
                self.assertEqual(self.run_fixture(fixture), 0)
                self.assertEqual(parse(self.output), expected)

    def test_undeclared_device_uses_guid(self):
        os.environ["FAKE_ZPOOL_FIXTURE"] = os.path.join(FIXTURES, "zpool-online.json")
        os.environ["FAKE_ZPOOL_EXIT"] = "0"
        self.assertEqual(host_telemetry.main([
            "zpool", "--zpool", self.env.zpool, "--output", self.output, "--disk", f"rpool-a={self.disk_a}",
        ]), 0)
        samples = parse(self.output)
        self.assertIn('homelab_zpool_vdev_errors{pool="rpool",type="read",vdev="guid-1002"}', samples)

    def test_failing_command_keeps_previous_file(self):
        self.assertEqual(self.run_fixture("zpool-online.json"), 0)
        before = read(self.output)
        past = time.time() - 3600
        os.utime(self.output, (past, past))
        mtime = os.stat(self.output).st_mtime
        self.assertEqual(self.run_fixture(None, exit_code=1), host_telemetry.COLLECTION_FAILED)
        self.assertEqual(read(self.output), before)
        self.assertEqual(os.stat(self.output).st_mtime, mtime)
        # Invalid JSON with a zero exit status is a failure too.
        self.assertEqual(self.run_fixture("smart-command-line-error.json"), host_telemetry.COLLECTION_FAILED)
        self.assertEqual(os.stat(self.output).st_mtime, mtime)
        self.assertEqual(os.listdir(self.env.output_dir), ["zpool.prom"])


class SmartTest(unittest.TestCase):
    def setUp(self):
        self.env = Environment()
        env = self.env
        self.disks = {}
        for name, node, link in (
            ("media1", "sda", "by-id/wwn-0x5000c50000000001"),
            ("spare-c", "sdb", "by-id/wwn-0x5000c50000000002"),
            ("rpool-a", "nvme0n1", "by-path/pci-a-nvme-1"),
        ):
            self.disks[name] = env.link(link, env.node(node))
        self.output = os.path.join(env.output_dir, "smart.prom")
        self.plan_path = os.path.join(env.dir, "plan.json")
        os.environ["FAKE_SMART_PLAN"] = self.plan_path

    def tearDown(self):
        self.env.close()

    def run_plan(self, plan):
        entries = {}
        for name, value in plan.items():
            if value == "broken":
                entries[self.disks[name]] = {"broken": True}
            else:
                fixture, code = value
                entries[self.disks[name]] = {"fixture": os.path.join(FIXTURES, fixture), "exit": code}
        with open(self.plan_path, "w") as handle:
            json.dump(entries, handle)
        args = ["smart", "--smartctl", self.env.smartctl, "--output", self.output]
        for name in sorted(self.disks):
            args += ["--disk", f"{name}={self.disks[name]}"]
        return host_telemetry.main(args)

    def labels(self, name):
        return f'disk="{name}",id="{os.path.basename(self.disks[name])}"'

    def healthy_plan(self):
        return {
            "media1": ("smart-sas-healthy.json", 0),
            "spare-c": ("smart-sata-healthy.json", 0),
            "rpool-a": ("smart-nvme-healthy.json", 0),
        }

    def test_healthy_sas_sata_and_nvme(self):
        self.assertEqual(self.run_plan(self.healthy_plan()), 0)
        samples = parse(self.output)
        for name in self.disks:
            self.assertEqual(samples[f"homelab_smart_device_up{{{self.labels(name)}}}"], 1)
            self.assertEqual(samples[f"homelab_smart_healthy{{{self.labels(name)}}}"], 1)
        self.assertEqual(samples[f"homelab_smart_scsi_grown_defects{{{self.labels('media1')}}}"], 0)
        self.assertEqual(samples[f"homelab_smart_ata_reallocated_sectors{{{self.labels('spare-c')}}}"], 0)
        self.assertEqual(samples[f"homelab_smart_ata_pending_sectors{{{self.labels('spare-c')}}}"], 0)
        self.assertEqual(samples[f"homelab_smart_nvme_critical_warning{{{self.labels('rpool-a')}}}"], 0)
        self.assertEqual(samples[f"homelab_smart_temperature_celsius{{{self.labels('media1')}}}"], 34)

    def test_failed_drive(self):
        plan = self.healthy_plan()
        plan["spare-c"] = ("smart-sata-failed.json", 8)
        self.assertEqual(self.run_plan(plan), 0)
        samples = parse(self.output)
        self.assertEqual(samples[f"homelab_smart_device_up{{{self.labels('spare-c')}}}"], 1)
        self.assertEqual(samples[f"homelab_smart_healthy{{{self.labels('spare-c')}}}"], 0)
        self.assertEqual(samples[f"homelab_smart_ata_reallocated_sectors{{{self.labels('spare-c')}}}"], 412)
        self.assertEqual(samples[f"homelab_smart_ata_pending_sectors{{{self.labels('spare-c')}}}"], 24)

    def test_grown_defects_rise(self):
        self.assertEqual(self.run_plan(self.healthy_plan()), 0)
        key = f"homelab_smart_scsi_grown_defects{{{self.labels('media1')}}}"
        self.assertEqual(parse(self.output)[key], 0)
        plan = self.healthy_plan()
        plan["media1"] = ("smart-sas-grown-defects.json", 0)
        self.assertEqual(self.run_plan(plan), 0)
        samples = parse(self.output)
        self.assertEqual(samples[key], 17)
        self.assertEqual(samples[f"homelab_smart_healthy{{{self.labels('media1')}}}"], 1)

    def test_unopenable_disk_reports_down_and_others_still_written(self):
        # An open failure, and a missing device smartctl cannot type.
        for fixture, code in (("smart-open-failed.json", 2), ("smart-command-line-error.json", 1)):
            plan = self.healthy_plan()
            plan["media1"] = (fixture, code)
            self.assertEqual(self.run_plan(plan), 0)
            samples = parse(self.output)
            self.assertEqual(samples[f"homelab_smart_device_up{{{self.labels('media1')}}}"], 0)
            self.assertNotIn(f"homelab_smart_healthy{{{self.labels('media1')}}}", samples)
            self.assertEqual(samples[f"homelab_smart_device_up{{{self.labels('spare-c')}}}"], 1)
            self.assertEqual(samples[f"homelab_smart_device_up{{{self.labels('rpool-a')}}}"], 1)

    def test_smartctl_failure_keeps_previous_file(self):
        self.assertEqual(self.run_plan(self.healthy_plan()), 0)
        before = read(self.output)
        past = time.time() - 3600
        os.utime(self.output, (past, past))
        mtime = os.stat(self.output).st_mtime
        for failure in ("broken", ("zpool-online.json", 0)):
            plan = self.healthy_plan()
            plan["spare-c"] = failure
            self.assertEqual(self.run_plan(plan), host_telemetry.COLLECTION_FAILED)
            self.assertEqual(read(self.output), before)
            self.assertEqual(os.stat(self.output).st_mtime, mtime)
        missing = host_telemetry.main([
            "smart", "--smartctl", os.path.join(self.env.dir, "absent"), "--output", self.output,
            "--disk", f"media1={self.disks['media1']}",
        ])
        self.assertEqual(missing, host_telemetry.COLLECTION_FAILED)
        self.assertEqual(os.stat(self.output).st_mtime, mtime)
        self.assertEqual(os.listdir(self.env.output_dir), ["smart.prom"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

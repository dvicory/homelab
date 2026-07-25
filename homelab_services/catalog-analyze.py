#!/usr/bin/env python3
"""Stream rclone catalogs into SQLite and emit bounded classification reports."""

from __future__ import annotations

import argparse
import csv
import difflib
import gzip
import hashlib
import heapq
import json
import os
import re
import shutil
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, TextIO

CATALOG_SUFFIX = ".lsjson.gz"
COMPANION_SUFFIXES = (".lsjson.gz", ".rclone.log", ".metadata.txt", ".sha256")
BATCH_SIZE = 10_000
PROGRESS_EVERY = 500_000
SUMMARY_DEPTH = 3
MAX_JSON_OBJECT = 64 << 20
FUZZY_MIN_SIZE = 1 << 20

CATEGORY_NAMES = (
    "video",
    "audio",
    "image",
    "document",
    "archive",
    "vm-image",
    "database",
    "config-code",
    "subtitle",
    "other",
)
CATEGORY_INDEX = {name: index for index, name in enumerate(CATEGORY_NAMES)}

EXTENSIONS = {
    "video": {"3g2", "3gp", "asf", "avi", "divx", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ogm", "ogv", "rm", "rmvb", "ts", "vob", "webm", "wmv"},
    "audio": {"aac", "aiff", "alac", "ape", "dsf", "flac", "m4a", "mid", "midi", "mp3", "oga", "ogg", "opus", "wav", "wma"},
    "image": {"avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif", "ico", "jpeg", "jpg", "nef", "orf", "png", "psd", "raf", "raw", "svg", "tif", "tiff", "webp"},
    "document": {"csv", "doc", "docx", "epub", "key", "md", "numbers", "ods", "odt", "pages", "pdf", "ppt", "pptx", "rtf", "tex", "txt", "xls", "xlsx"},
    "archive": {"7z", "bz2", "cab", "gz", "lz4", "rar", "tar", "tbz", "tbz2", "tgz", "txz", "xz", "zip", "zst"},
    "vm-image": {"img", "iso", "ova", "ovf", "qcow", "qcow2", "raw", "vdi", "vhd", "vhdx", "vma", "vmdk"},
    "database": {"db", "db3", "dump", "frm", "ibd", "mdb", "myd", "myi", "psql", "sqlite", "sqlite3", "sql"},
    "config-code": {"cfg", "conf", "css", "env", "go", "h", "html", "ini", "java", "js", "json", "jsx", "lock", "lua", "nix", "php", "pl", "properties", "py", "rb", "rs", "sh", "toml", "ts", "tsx", "xml", "yaml", "yml"},
    "subtitle": {"ass", "idx", "smi", "srt", "ssa", "sub", "sup", "vtt"},
}

DESTINATION_KEYWORDS = {
    "personal-mirror": {
        "documents", "document", "fileserver", "home", "homes", "nextcloud", "owncloud", "personal", "photo", "photos", "pictures", "resilio", "spock", "sync", "users",
    },
    "services-mirror": {
        "appdata", "application", "bazarr", "caddy", "config", "database", "docker", "freshrss", "immich", "jellyfin", "nextcloud", "postgres", "radarr", "recyclarr", "sabnzbd", "sonarr", "stacks",
    },
    "bulk-media": {
        "audio", "downloads", "incoming", "library", "mccoy", "media", "medialibrary", "movie", "movies", "music", "series", "shows", "television", "torrent", "tv", "video",
    },
    "static-proxmox": {
        "backup", "backups", "dump", "images", "iso", "kirk", "pve", "pve1", "qemu", "snapshot", "snapshots", "subvol", "template", "templates", "vma", "vm", "vms", "vzdump",
    },
    "disposable-review": {
        "cache", "cached", "incomplete", "lostfound", "redshirt", "scratch", "temp", "temporary", "tmp", "transcode", "transcodes",
    },
}

NOISE_TOKENS = {
    "1080p", "2160p", "480p", "720p", "aac", "ac3", "bluray", "brrip", "dts", "dvdrip", "h264", "h265", "hdr", "hevc", "proper", "remux", "repack", "uhd", "web", "webdl", "webrip", "x264", "x265",
}

SCHEMA = """
CREATE TABLE catalogs (
    id INTEGER PRIMARY KEY,
    label TEXT NOT NULL UNIQUE,
    catalog_file TEXT NOT NULL,
    source_root TEXT,
    source_host TEXT,
    started_utc TEXT,
    imported_utc TEXT NOT NULL,
    entry_count INTEGER NOT NULL DEFAULT 0,
    file_count INTEGER NOT NULL DEFAULT 0,
    directory_count INTEGER NOT NULL DEFAULT 0,
    link_count INTEGER NOT NULL DEFAULT 0,
    file_bytes INTEGER NOT NULL DEFAULT 0,
    category_counts TEXT NOT NULL DEFAULT '{}',
    category_bytes TEXT NOT NULL DEFAULT '{}',
    log_summary TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE entries (
    catalog_id INTEGER NOT NULL,
    path TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime TEXT,
    kind INTEGER NOT NULL,
    category INTEGER,
    name_key TEXT,
    PRIMARY KEY (catalog_id, path),
    FOREIGN KEY (catalog_id) REFERENCES catalogs(id)
) WITHOUT ROWID;
CREATE TABLE directory_stats (
    catalog_id INTEGER NOT NULL,
    path TEXT NOT NULL,
    depth INTEGER NOT NULL,
    file_count INTEGER NOT NULL,
    directory_count INTEGER NOT NULL,
    link_count INTEGER NOT NULL,
    file_bytes INTEGER NOT NULL,
    category_counts TEXT NOT NULL,
    category_bytes TEXT NOT NULL,
    PRIMARY KEY (catalog_id, path),
    FOREIGN KEY (catalog_id) REFERENCES catalogs(id)
) WITHOUT ROWID;
"""


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def verify_collection(artifacts: Path, label: str) -> None:
    checksum_path = artifacts / f"{label}.sha256"
    expected: dict[str, str] = {}
    for line in checksum_path.read_text(encoding="utf-8").splitlines():
        digest, name = line.split(maxsplit=1)
        expected[name.lstrip("*")] = digest
    required = {f"{label}{suffix}" for suffix in COMPANION_SUFFIXES[:-1]}
    missing_from_manifest = required - expected.keys()
    if missing_from_manifest:
        raise ValueError(f"{checksum_path}: missing checksum entries: {sorted(missing_from_manifest)}")
    for name, digest in expected.items():
        path = artifacts / name
        if not path.is_file():
            raise FileNotFoundError(path)
        actual = sha256_file(path)
        if actual != digest:
            raise ValueError(f"checksum mismatch: {path}")


def parse_metadata(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("--") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if re.fullmatch(r"[a-z_]+", key):
            result[key] = value
    return result

def summarize_log(path: Path) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            counts["lines"] += 1
            match = re.search(r"\b(CRITICAL|ERROR|WARNING|NOTICE|INFO|DEBUG)\s*:", line)
            level = match.group(1).lower() if match else "unclassified"
            counts[level] += 1
            lowered = line.casefold()
            if "can't follow symlink" in lowered:
                counts["symlink_omitted"] += 1
            if "permission denied" in lowered:
                counts["permission_denied"] += 1
            if "invalid utf" in lowered or "replacing invalid" in lowered:
                counts["invalid_filename_encoding"] += 1
            if level in {"critical", "error"}:
                counts["serious"] += 1
    return dict(sorted(counts.items()))


def iter_json_array(stream: TextIO, chunk_size: int = 1 << 20) -> Iterator[dict[str, Any]]:
    """Incrementally decode a top-level JSON array without retaining the array."""
    decoder = json.JSONDecoder()
    buffer = ""
    position = 0
    eof = False
    started = False

    def refill() -> None:
        nonlocal buffer, position, eof
        if position:
            buffer = buffer[position:]
            position = 0
        chunk = stream.read(chunk_size)
        if chunk:
            buffer += chunk
        else:
            eof = True

    while True:
        if position >= len(buffer) and not eof:
            refill()
        while position < len(buffer) and buffer[position].isspace():
            position += 1
        if not started:
            if position >= len(buffer):
                if eof:
                    raise ValueError("empty JSON input")
                refill()
                continue
            if buffer[position] != "[":
                raise ValueError("catalog is not a top-level JSON array")
            position += 1
            started = True
            continue

        while True:
            if position >= len(buffer):
                if eof:
                    raise ValueError("truncated JSON array")
                refill()
                continue
            char = buffer[position]
            if char.isspace() or char == ",":
                position += 1
                continue
            break
        if buffer[position] == "]":
            position += 1
            while True:
                while position < len(buffer) and buffer[position].isspace():
                    position += 1
                if position < len(buffer):
                    raise ValueError("unexpected data after JSON array")
                if eof:
                    return
                refill()
            
        while True:
            try:
                value, end = decoder.raw_decode(buffer, position)
                break
            except json.JSONDecodeError:
                if eof:
                    raise ValueError("malformed or truncated JSON object")
                if len(buffer) - position > MAX_JSON_OBJECT:
                    raise ValueError("JSON object exceeds bounded parser limit")
                refill()
        if not isinstance(value, dict):
            raise ValueError("catalog array contains a non-object value")
        position = end
        yield value
        if position > chunk_size:
            refill()


def normalized_text(value: str) -> str:
    folded = unicodedata.normalize("NFKD", value.casefold())
    return "".join(char for char in folded if not unicodedata.combining(char))


def fuzzy_name_key(path: str) -> str | None:
    name = path.rsplit("/", 1)[-1]
    if name.endswith(".rclonelink"):
        name = name[:-11]
    if "." in name and not name.startswith("."):
        name = name.rsplit(".", 1)[0]
    value = normalized_text(name)
    value = re.sub(r"[\[({].*?[\])}]", " ", value)
    tokens = re.findall(r"[a-z0-9]+", value)
    tokens = [token for token in tokens if token not in NOISE_TOKENS and not re.fullmatch(r"(?:19|20)\d{2}", token)]
    key = " ".join(tokens)
    return key if len(key) >= 3 else None


def file_category(path: str) -> int:
    name = path.rsplit("/", 1)[-1]
    if name.endswith(".rclonelink"):
        name = name[:-11]
    extension = name.rsplit(".", 1)[-1].casefold() if "." in name else ""
    normalized_path = normalized_text(path)
    if extension == "ts":
        media_tokens = ("/media/", "/medialibrary/", "/movies/", "/tv/", "/video/")
        return CATEGORY_INDEX["video"] if any(token in normalized_path for token in media_tokens) else CATEGORY_INDEX["config-code"]
    if extension in EXTENSIONS["vm-image"] and any(token in normalized_path for token in ("pve", "qemu", "vm", "vzdump", "images")):
        return CATEGORY_INDEX["vm-image"]
    for category, extensions in EXTENSIONS.items():
        if extension in extensions:
            return CATEGORY_INDEX[category]
    if any(token in normalized_path for token in ("/appdata/", "/config/", "/stacks/", "/etc/")):
        return CATEGORY_INDEX["config-code"]
    return CATEGORY_INDEX["other"]


def path_prefixes(path: str, kind: int) -> list[tuple[int, str]]:
    parts = [part for part in path.split("/") if part]
    if kind != 1:
        parts = parts[:-1]
    if not parts:
        return [(0, ".")]
    return [(depth, "/".join(parts[:depth])) for depth in range(1, min(SUMMARY_DEPTH, len(parts)) + 1)]


def empty_stats() -> list[Any]:
    return [0, 0, 0, 0, [0] * len(CATEGORY_NAMES), [0] * len(CATEGORY_NAMES)]


def update_stats(stats: list[Any], kind: int, size: int, category: int | None) -> None:
    if kind == 0:
        stats[0] += 1
        stats[3] += max(size, 0)
        if category is not None:
            stats[4][category] += 1
            stats[5][category] += max(size, 0)
    elif kind == 1:
        stats[1] += 1
    else:
        stats[2] += 1


def import_catalog(connection: sqlite3.Connection, artifacts: Path, catalog_path: Path) -> None:
    label = catalog_path.name[: -len(CATALOG_SUFFIX)]
    print(f"Verifying {label} checksums...", flush=True)
    verify_collection(artifacts, label)
    metadata = parse_metadata(artifacts / f"{label}.metadata.txt")
    cursor = connection.execute(
        "INSERT INTO catalogs(label, catalog_file, source_root, source_host, started_utc, imported_utc) VALUES (?, ?, ?, ?, ?, ?)",
        (label, catalog_path.name, metadata.get("root"), metadata.get("host"), metadata.get("started_utc"), utc_now()),
    )
    catalog_id = int(cursor.lastrowid)
    totals = empty_stats()
    directory: dict[str, list[Any]] = defaultdict(empty_stats)
    batch: list[tuple[Any, ...]] = []
    seen = 0

    print(f"Importing {label} with bounded memory...", flush=True)
    with gzip.open(catalog_path, "rt", encoding="utf-8", errors="strict") as stream:
        for item in iter_json_array(stream):
            path = item.get("Path")
            if not isinstance(path, str) or not path:
                raise ValueError(f"{catalog_path}: entry {seen + 1} has no valid Path")
            is_directory = bool(item.get("IsDir"))
            is_link = not is_directory and path.endswith(".rclonelink")
            kind = 1 if is_directory else (2 if is_link else 0)
            raw_size = item.get("Size", 0)
            size = int(raw_size) if isinstance(raw_size, (int, float)) else 0
            mtime = item.get("ModTime") if isinstance(item.get("ModTime"), str) else None
            category = file_category(path) if kind == 0 else None
            name_key = fuzzy_name_key(path) if kind == 0 and size >= FUZZY_MIN_SIZE else None
            batch.append((catalog_id, path, size, mtime, kind, category, name_key))
            update_stats(totals, kind, size, category)
            for _depth, prefix in path_prefixes(path, kind):
                update_stats(directory[prefix], kind, size, category)
            seen += 1
            if len(batch) >= BATCH_SIZE:
                connection.executemany("INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?)", batch)
                batch.clear()
            if seen % PROGRESS_EVERY == 0:
                print(f"  {label}: {seen:,} entries", flush=True)
    if batch:
        connection.executemany("INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?)", batch)

    directory_rows = []
    for prefix, stats in directory.items():
        directory_rows.append(
            (
                catalog_id,
                prefix,
                0 if prefix == "." else prefix.count("/") + 1,
                stats[0],
                stats[1],
                stats[2],
                stats[3],
                json.dumps(dict(zip(CATEGORY_NAMES, stats[4])), separators=(",", ":")),
                json.dumps(dict(zip(CATEGORY_NAMES, stats[5])), separators=(",", ":")),
            )
        )
    connection.executemany("INSERT INTO directory_stats VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", directory_rows)
    connection.execute(
        """UPDATE catalogs SET entry_count=?, file_count=?, directory_count=?, link_count=?, file_bytes=?, category_counts=?, category_bytes=?, log_summary=? WHERE id=?""",
        (
            seen,
            totals[0],
            totals[1],
            totals[2],
            totals[3],
            json.dumps(dict(zip(CATEGORY_NAMES, totals[4])), separators=(",", ":")),
            json.dumps(dict(zip(CATEGORY_NAMES, totals[5])), separators=(",", ":")),
            json.dumps(summarize_log(artifacts / f"{label}.rclone.log"), separators=(",", ":")),
            catalog_id,
        ),
    )
    connection.commit()
    print(f"Imported {label}: {seen:,} entries", flush=True)


def keyword_matches(path: str, keywords: set[str]) -> list[str]:
    normalized = normalized_text(path)
    tokens = set(re.findall(r"[a-z0-9]+", normalized))
    matches: set[str] = set()
    for keyword in keywords:
        if keyword in tokens or (len(keyword) >= 5 and keyword in normalized):
            matches.add(keyword)
            continue
        for token in tokens:
            if min(len(keyword), len(token)) >= 5 and difflib.SequenceMatcher(None, keyword, token).ratio() >= 0.86:
                matches.add(f"{token}~{keyword}")
                break
    return sorted(matches)


def classify_directory(path: str, file_count: int, file_bytes: int, category_counts: dict[str, int], category_bytes: dict[str, int]) -> tuple[str, str, str]:
    scores: dict[str, float] = defaultdict(float)
    reasons: list[str] = []
    for destination, keywords in DESTINATION_KEYWORDS.items():
        matches = keyword_matches(path, keywords)
        if matches:
            weight = 2.0 if destination == "disposable-review" else 2.5
            scores[destination] += weight * min(len(matches), 3)
            reasons.append(f"{destination} keywords={','.join(matches[:4])}")

    total_bytes = max(file_bytes, 1)
    total_count = max(file_count, 1)
    ratios = {name: category_bytes.get(name, 0) / total_bytes for name in CATEGORY_NAMES}
    count_ratios = {name: category_counts.get(name, 0) / total_count for name in CATEGORY_NAMES}
    if ratios["video"] + ratios["audio"] + ratios["subtitle"] >= 0.55:
        scores["bulk-media"] += 6
        reasons.append("media-majority-bytes")
    if ratios["image"] + ratios["document"] >= 0.45:
        scores["personal-mirror"] += 6
        reasons.append("personal-content-majority-bytes")
    if ratios["database"] + ratios["config-code"] >= 0.20 or count_ratios["database"] + count_ratios["config-code"] >= 0.35:
        scores["services-mirror"] += 5
        reasons.append("state/config-density")
    if ratios["vm-image"] >= 0.35:
        scores["static-proxmox"] += 6
        reasons.append("vm-image-majority-bytes")
    if ratios["archive"] >= 0.65:
        scores["static-proxmox"] += 2
        reasons.append("archive-majority-bytes")

    category_destinations = {
        "video": "bulk-media",
        "audio": "bulk-media",
        "subtitle": "bulk-media",
        "image": "personal-mirror",
        "document": "personal-mirror",
        "database": "services-mirror",
        "config-code": "services-mirror",
        "vm-image": "static-proxmox",
        "archive": "static-proxmox",
    }
    significant_destinations = {
        category_destinations[name]
        for name, ratio in ratios.items()
        if ratio >= 0.15 and name in category_destinations
    }
    if len(significant_destinations) > 1:
        return "manual-review", "low", "; ".join(reasons + [f"mixed-content={','.join(sorted(significant_destinations))}"])
    if not scores:
        return "manual-review", "low", "no-strong-signal"
    ranked = sorted(scores.items(), key=lambda item: (-item[1], item[0]))
    destination, score = ranked[0]
    margin = score - (ranked[1][1] if len(ranked) > 1 else 0)
    if destination == "disposable-review" and (ratios["image"] + ratios["document"] + ratios["database"] > 0.05):
        return "manual-review", "low", "; ".join(reasons + ["disposable-signal-conflicts-with-stateful-content"])
    confidence = "high" if score >= 6 and margin >= 3 else ("medium" if score >= 4 and margin >= 1.5 else "low")
    if confidence == "low":
        destination = "manual-review"
    return destination, confidence, "; ".join(reasons)


def scalar(connection: sqlite3.Connection, query: str) -> int:
    row = connection.execute(query).fetchone()
    return int(row[0] or 0)


def load_overrides(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("version") != 1 or not isinstance(document.get("rules"), list):
        raise ValueError(f"{path}: expected override version 1 with a rules array")
    rules: list[dict[str, Any]] = []
    for index, rule in enumerate(document["rules"], start=1):
        if not isinstance(rule, dict) or not isinstance(rule.get("catalog"), str) or not isinstance(rule.get("prefix"), str):
            raise ValueError(f"{path}: invalid rule {index}")
        rules.append(rule)
    return rules


def apply_overrides(
    rules: list[dict[str, Any]],
    label: str,
    path: str,
    destination: str,
    confidence: str,
    reasons: str,
) -> tuple[str, str, str, str, str, str, str]:
    authority = "unknown"
    criticality = "unknown"
    action = "review"
    source = "heuristic"
    matched: list[str] = []
    for rule in rules:
        prefix = rule["prefix"].strip("/")
        if rule["catalog"] != label:
            continue
        if path != prefix and not (rule.get("recursive", False) and path.startswith(prefix + "/")):
            continue
        authority = rule.get("authority", authority)
        criticality = rule.get("criticality", criticality)
        action = rule.get("action", action)
        if "destination" in rule:
            destination = rule["destination"]
            confidence = "owner"
        source = "owner-override"
        matched.append(prefix)
    if matched:
        suffix = f"owner-rules={','.join(matched)}"
        reasons = f"{reasons}; {suffix}" if reasons else suffix
    return destination, confidence, reasons, authority, criticality, action, source


def emit_reports(connection: sqlite3.Connection, report_dir: Path, overrides: list[dict[str, Any]]) -> None:
    report_dir.mkdir(parents=True, exist_ok=False)
    catalogs = []
    catalog_names: dict[int, str] = {}
    for row in connection.execute(
        "SELECT id,label,source_root,source_host,entry_count,file_count,directory_count,link_count,file_bytes,category_counts,category_bytes,log_summary FROM catalogs ORDER BY label"
    ):
        catalog_names[row[0]] = row[1]
        catalogs.append(
            {
                "label": row[1],
                "source_root": row[2],
                "source_host": row[3],
                "entry_count": row[4],
                "file_count": row[5],
                "directory_count": row[6],
                "link_count": row[7],
                "file_bytes": row[8],
                "category_counts": json.loads(row[9]),
                "category_bytes": json.loads(row[10]),
                "log_summary": json.loads(row[11]),
            }
        )

    exact_groups = scalar(
        connection,
        "SELECT COUNT(*) FROM (SELECT path,size FROM entries WHERE kind=0 GROUP BY path,size HAVING COUNT(*) > 1)",
    )
    fuzzy_groups = scalar(
        connection,
        "SELECT COUNT(*) FROM (SELECT size,name_key FROM entries WHERE kind=0 AND name_key IS NOT NULL GROUP BY size,name_key HAVING COUNT(*) > 1 AND COUNT(DISTINCT catalog_id) > 1)",
    )
    overview = {
        "generated_utc": utc_now(),
        "database_schema": 1,
        "catalogs": catalogs,
        "candidate_groups": {
            "exact_relative_path_and_size": exact_groups,
            "fuzzy_name_and_exact_size_cross_catalog": fuzzy_groups,
            "warning": "Candidates are not verified duplicates; payload hashes were intentionally not read.",
        },
    }
    (report_dir / "overview.json").write_text(json.dumps(overview, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    classification_counts: dict[str, int] = defaultdict(int)
    top_directories: dict[str, list[tuple[int, str, dict[str, Any]]]] = defaultdict(list)
    review_rows: list[tuple[Any, ...]] = []
    report_header = (
        "catalog", "path", "depth", "file_count", "directory_count", "link_count", "file_bytes",
        "suggested_destination", "confidence", "authority", "criticality", "action", "decision_source", "reasons",
    )
    with (report_dir / "directory-classification.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(report_header)
        rows = connection.execute(
            "SELECT catalog_id,path,depth,file_count,directory_count,link_count,file_bytes,category_counts,category_bytes FROM directory_stats ORDER BY catalog_id,depth,path"
        )
        for row in rows:
            category_counts = json.loads(row[7])
            category_bytes = json.loads(row[8])
            destination, confidence, reasons = classify_directory(row[1], row[3], row[6], category_counts, category_bytes)
            label = catalog_names[row[0]]
            destination, confidence, reasons, authority, criticality, action, source = apply_overrides(
                overrides, label, row[1], destination, confidence, reasons
            )
            classification_counts[f"{destination}:{confidence}"] += 1
            report_row = (
                label, row[1], row[2], row[3], row[4], row[5], row[6], destination, confidence,
                authority, criticality, action, source, reasons,
            )
            writer.writerow(report_row)
            if destination in {"manual-review", "disposable-review"} or confidence not in {"high", "owner"}:
                review_rows.append(report_row)
            item = {
                "path": row[1],
                "depth": row[2],
                "file_count": row[3],
                "file_bytes": row[6],
                "suggested_destination": destination,
                "confidence": confidence,
                "authority": authority,
                "criticality": criticality,
                "action": action,
            }
            candidate = (row[6], row[1], item)
            heap = top_directories[label]
            if len(heap) < 200:
                heapq.heappush(heap, candidate)
            elif candidate[:2] > heap[0][:2]:
                heapq.heapreplace(heap, candidate)
    review_rows.sort(key=lambda row: (-row[6], row[0], row[1]))
    with (report_dir / "review-queue.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(report_header)
        writer.writerows(review_rows)
    bounded_top = {
        label: sorted((candidate[2] for candidate in rows), key=lambda item: (-item["file_bytes"], item["path"]))
        for label, rows in top_directories.items()
    }
    (report_dir / "top-directories.json").write_text(json.dumps(bounded_top, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    (report_dir / "classification-summary.json").write_text(
        json.dumps(dict(sorted(classification_counts.items())), indent=2) + "\n", encoding="utf-8"
    )

    pair_totals: dict[tuple[int, int], list[int]] = defaultdict(lambda: [0, 0])
    grouped_query = """
        SELECT size,GROUP_CONCAT(catalog_id)
        FROM entries INDEXED BY entries_size_name
        WHERE kind=0 AND size>=1048576 AND name_key IS NOT NULL
        GROUP BY size,name_key
        HAVING COUNT(*) BETWEEN 2 AND 20 AND COUNT(DISTINCT catalog_id)>1
    """
    for size, catalog_ids in connection.execute(grouped_query):
        counts = Counter(int(value) for value in catalog_ids.split(","))
        ids = sorted(counts)
        for left_index, left in enumerate(ids):
            for right in ids[left_index + 1 :]:
                pairs = counts[left] * counts[right]
                totals = pair_totals[(left, right)]
                totals[0] += pairs
                totals[1] += pairs * size
    with (report_dir / "cross-catalog-matches.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(("match_type", "catalog_a", "catalog_b", "candidate_pairs", "candidate_bytes"))
        for (left, right), totals in sorted(
            pair_totals.items(), key=lambda item: (catalog_names[item[0][0]], catalog_names[item[0][1]])
        ):
            writer.writerow(
                ("fuzzy-name-and-exact-size", catalog_names[left], catalog_names[right], totals[0], totals[1])
            )


def build(args: argparse.Namespace) -> None:
    artifacts = args.artifacts.resolve()
    database = args.database.resolve()
    reports = args.reports.resolve()
    catalogs = sorted(artifacts.glob(f"*{CATALOG_SUFFIX}"))
    if not catalogs:
        raise FileNotFoundError(f"no *{CATALOG_SUFFIX} files in {artifacts}")
    for catalog in catalogs:
        label = catalog.name[: -len(CATALOG_SUFFIX)]
        missing = [suffix for suffix in COMPANION_SUFFIXES if not (artifacts / f"{label}{suffix}").is_file()]
        if missing:
            raise FileNotFoundError(f"{label}: missing companions {missing}")
    if database.exists() or reports.exists():
        if not args.force:
            raise FileExistsError("database or report directory exists; use --force to rebuild")
        if database.exists():
            database.unlink()
        if reports.exists():
            shutil.rmtree(reports)
    database.parent.mkdir(parents=True, exist_ok=True)
    partial = database.with_name(database.name + ".partial")
    if partial.exists():
        partial.unlink()

    connection = sqlite3.connect(partial)
    try:
        connection.execute("PRAGMA page_size=32768")
        connection.execute("PRAGMA journal_mode=OFF")
        connection.execute("PRAGMA synchronous=OFF")
        connection.execute("PRAGMA temp_store=FILE")
        connection.execute("PRAGMA cache_size=-262144")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.executescript(SCHEMA)
        for catalog in catalogs:
            import_catalog(connection, artifacts, catalog)
        print("Building query indexes...", flush=True)
        connection.execute("CREATE INDEX entries_path_size ON entries(path,size,catalog_id) WHERE kind=0")
        connection.execute("CREATE INDEX entries_size_name ON entries(size,name_key,catalog_id) WHERE kind=0 AND name_key IS NOT NULL")
        connection.execute("ANALYZE")
        connection.commit()
        emit_reports(connection, reports, load_overrides(args.overrides.resolve()))
    finally:
        connection.close()
    os.replace(partial, database)
    print(f"Database: {database}")
    print(f"Bounded reports: {reports}")


def show_status(args: argparse.Namespace) -> None:
    database = args.database.resolve()
    partial = database.with_name(database.name + ".partial")
    active = database if database.exists() else partial
    if not active.exists():
        raise FileNotFoundError(f"no analyzer database or partial database at {database}")
    connection = sqlite3.connect(f"file:{active}?mode=ro", uri=True, timeout=5)
    try:
        catalogs = [
            {
                "label": row[0],
                "entries": row[1],
                "files": row[2],
                "directories": row[3],
                "links": row[4],
            }
            for row in connection.execute(
                "SELECT label,entry_count,file_count,directory_count,link_count FROM catalogs ORDER BY id"
            )
        ]
        indexes = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('entries_path_size','entries_size_name')"
            )
        }
    finally:
        connection.close()
    reports = args.reports.resolve()
    report_files = sorted(path.name for path in reports.iterdir()) if reports.is_dir() else []
    if database.exists() and "overview.json" in report_files:
        stage = "complete"
    elif len(indexes) == 2:
        stage = "indexes-built; analyzing and generating bounded reports"
    else:
        stage = "importing catalogs or building indexes"
    print(
        json.dumps(
            {
                "stage": stage,
                "database": str(active),
                "database_bytes": active.stat().st_size,
                "catalogs": catalogs,
                "total_entries_committed": sum(item["entries"] for item in catalogs),
                "indexes": sorted(indexes),
                "report_files": report_files,
            },
            indent=2,
        )
    )


def resume_reports(args: argparse.Namespace) -> None:
    database = args.database.resolve()
    partial = database.with_name(database.name + ".partial")
    active = partial if partial.exists() else database
    if not active.exists():
        raise FileNotFoundError(f"no complete or partial database at {database}")
    reports = args.reports.resolve()
    if reports.exists():
        shutil.rmtree(reports)
    connection = sqlite3.connect(active)
    try:
        indexes = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('entries_path_size','entries_size_name')"
            )
        }
        if indexes != {"entries_path_size", "entries_size_name"}:
            raise ValueError("partial database has not completed both query indexes")
        emit_reports(connection, reports, load_overrides(args.overrides.resolve()))
    finally:
        connection.close()
    if active == partial:
        os.replace(partial, database)
    print(f"Database: {database}")
    print(f"Bounded reports: {reports}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=Path("homelab_services/artifacts"))
    parser.add_argument("--database", type=Path, default=Path("homelab_services/artifacts/catalog.sqlite"))
    parser.add_argument("--reports", type=Path, default=Path("homelab_services/artifacts/catalog-reports"))
    parser.add_argument("--overrides", type=Path, default=Path("homelab_services/catalog-overrides.json"))
    parser.add_argument("--force", action="store_true", help="replace an existing derived database/reports")
    parser.add_argument("--status", action="store_true", help="show bounded progress without reading catalog contents")
    parser.add_argument(
        "--resume-reports",
        action="store_true",
        help="regenerate bounded reports from a fully indexed database",
    )
    return parser.parse_args()


def main() -> int:
    try:
        args = parse_args()
        if args.status:
            show_status(args)
        elif args.resume_reports:
            resume_reports(args)
        else:
            build(args)
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

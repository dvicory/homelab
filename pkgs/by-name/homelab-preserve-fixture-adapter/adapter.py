import json
import os
import pathlib
import sys

PROTOCOL_VERSION = 1
MAX_REQUEST_BYTES = 1_048_576
CONTENT = "fixture-content\n"
POINT_ID = "fixture-point-1"


def response(request_id, result=None, error=None):
    value = {"protocolVersion": PROTOCOL_VERSION, "requestId": request_id}
    if error is None:
        value["result"] = result
    else:
        value["error"] = error
    sys.stdout.write(json.dumps(value, separators=(",", ":")))


def point(request):
    return {
        "stateId": request["stateId"],
        "routeId": request["routeId"],
        "targetId": request["targetId"],
        "owner": "fixture-owner",
        "nativeId": POINT_ID,
        "captureId": "fixture-capture-1",
        "capturedAt": "2026-09-14T00:00:00Z",
        "retainedAt": "2026-09-14T00:00:01Z",
        "completion": "complete",
        "consistency": "filesystem",
        "scope": {"kind": "fixture-tree", "recursive": False},
        "nativeRepresentation": {"kind": "fixture-directory/v1"},
        "payloadRepresentation": None,
        "verification": [{"kind": "fixture-native-check", "status": "passed"}],
        "producerProvenance": {
            "fixture.applicationVersion": "1.2.3",
            "postgresql.serverVersion": "16",
            "application.schema": {"major": 4, "minor": 2},
        },
        "ownerProvenance": {
            "fixture.catalog": "point.json",
            "fixture.executable": "/does/not/execute",
        },
    }


def fixture_root(request):
    payload = request.get("ownerPayload") or {}
    native = payload.get("native") or payload
    root = native.get("root")
    if not isinstance(root, str) or not root:
        raise ValueError("owner payload requires native.root")
    return pathlib.Path(root)


def point_path(request):
    return fixture_root(request) / "point.json"


def handle(request):
    operation = request.get("operation")
    if operation == "describe":
        payload = request.get("ownerPayload") or {}
        native = payload.get("native") or payload
        return {
            "kind": "describe",
            "adapterVersion": {
                "protocolVersion": native.get("reportedProtocolVersion", PROTOCOL_VERSION),
                "implementation": "homelab-preserve-fixture-adapter",
                "implementationVersion": "1.0.0",
                "fixtureOnly": True,
            },
            "capabilities": native.get(
                "capabilities",
                ["describe", "status", "points", "run", "restore", "verify"],
            ),
            "explicitScratch": native.get("explicitScratch", True),
        }
    if operation == "status":
        exists = point_path(request).is_file()
        return {
            "kind": "status",
            "evidence": "observed",
            "catalogObserved": True,
            "pointCount": 1 if exists else 0,
            "details": {"catalog": "fixture", "empty": not exists},
        }
    if operation == "points":
        return {
            "kind": "points",
            "points": [point(request)] if point_path(request).is_file() else [],
        }
    if operation == "run":
        root = fixture_root(request)
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = root / "point.json.tmp"
        temporary.write_text(json.dumps(point(request)), encoding="utf-8")
        os.replace(temporary, root / "point.json")
        return {
            "kind": "run",
            "evidence": "retained",
            "details": {"nativeId": POINT_ID, "atomicAction": "fixture-retain"},
        }
    if operation == "restore":
        requested_point = request.get("point") or {}
        if requested_point.get("nativeId") != POINT_ID or not point_path(request).is_file():
            raise ValueError("selected fixture point does not exist")
        payload = request.get("ownerPayload") or {}
        native = payload.get("native") or payload
        destination = pathlib.Path(request["destination"]["path"])
        target_root = native.get("targetRoot")
        if isinstance(target_root, str) and target_root:
            root = pathlib.Path(target_root)
            if destination == root or root in destination.parents:
                raise ValueError("restore destination aliases the native target root")
        destination.mkdir(mode=0o700)
        (destination / "content.txt").write_text(CONTENT, encoding="utf-8")
        return {
            "kind": "restore",
            "ownerReceipt": {"content": "content.txt", "nativeId": POINT_ID},
        }
    if operation == "verify":
        receipt = request.get("receipt") or {}
        destination = pathlib.Path(receipt["destination"]["path"])
        content = destination / "content.txt"
        verified = content.is_file() and content.read_text(encoding="utf-8") == CONTENT
        return {
            "kind": "verify",
            "verified": verified,
            "evidence": "verified" if verified else "failed",
            "scope": "fixture-content",
            "details": {"checked": "content.txt"},
        }
    raise ValueError(f"unsupported operation {operation!r}")


def main():
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    request_id = "unknown"
    if len(raw) > MAX_REQUEST_BYTES:
        response(request_id, error={"code": "request-too-large", "message": "request too large"})
        return 0
    try:
        request = json.loads(raw)
        request_id = request.get("requestId", "unknown")
        if request.get("protocolVersion") != PROTOCOL_VERSION:
            response(
                request_id,
                error={"code": "incompatible-version", "message": "unsupported protocol version"},
            )
            return 0
        result = handle(request)
        response(request_id, result=result)
        return 0
    except Exception as error:
        response(request_id, error={"code": "fixture-error", "message": str(error)})
        return 0


if __name__ == "__main__":
    raise SystemExit(main())

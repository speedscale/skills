#!/usr/bin/env bash
# Picks the recorded inbound requests worth turning into test cases, so the
# agent reads one short JSON file instead of hundreds of RRPair files. It only
# reads the recording; nothing is written next to it.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: select-cases.sh --in DIR [--list] [--service NAME] [--per-endpoint N] [--out FILE]

  --in DIR          recording or pulled snapshot directory (proxymock/recorded-<name>,
                    proxymock/snapshot-<id>)
  --list            print the inbound services and their endpoints, then exit
  --service NAME    the inbound service to select cases for; required when the
                    recording holds more than one
  --per-endpoint N  distinct exchanges kept per endpoint and status (default 2)
  --out FILE        write the JSON there instead of stdout

Each case carries the request, the recorded response, where each volatile
response value came from, and the dependency calls made while handling it:
HTTP calls with their bodies, SQL with decoded parameters and result rows.
Credential headers are redacted.

Exits: 0 ok, 1 nothing to select, 2 usage or an ambiguous --service.
USAGE
}

die() { echo "select-cases: $*" >&2; exit 2; }

in_dir=""; list="0"; service=""; per="2"; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --list) list="1"; shift ;;
    --service) [[ $# -ge 2 ]] || die "--service requires a value"; service="$2"; shift 2 ;;
    --per-endpoint) [[ $# -ge 2 ]] || die "--per-endpoint requires a value"; per="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out requires a value"; out="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
[[ "$per" =~ ^[1-9][0-9]*$ ]] || die "--per-endpoint must be a positive integer"
command -v python3 >/dev/null 2>&1 || die "missing required command: python3"

python3 - "$in_dir" "$list" "$service" "$per" "$out" <<'PY'
import base64, hashlib, json, pathlib, re, struct, sys, uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qsl, urlsplit

root, list_only, want_service, per, out = (
    pathlib.Path(sys.argv[1]), sys.argv[2] == "1", sys.argv[3], int(sys.argv[4]), sys.argv[5])
# Dependency bodies too large to inline go to files beside --out, so the agent
# never has to dig a body out of an RRPair.
bodies_dir = pathlib.Path(out).with_name(pathlib.Path(out).stem + "-bodies") if out else None

INLINE_BODY_LIMIT = 8192
# A request's dependency calls end no later than this after its own recorded
# end, even when the next inbound request starts much later. Recorded
# durations are whole milliseconds and an HTTP call is stamped near its
# response, so a window of exactly ts..ts+duration misses the last calls.
TAIL = timedelta(milliseconds=250)
TICK = timedelta(milliseconds=1)

internal_re = re.compile(r"### INTERNAL - DO NOT MODIFY ###\s*```\s*json:\s*(\{.*?\})\s*```", re.S)
fence_re = re.compile(r"```[^\n]*\n(.*?)\n?```", re.S)
SECRET_HEADERS = {"authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key", "api-key", "x-auth-token"}
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$")
TOKEN_RE = re.compile(r"^(eyJ[\w-]+\.[\w-]+\.[\w-]+|[A-Za-z0-9_\-]{32,})$")
EPOCH_RE = re.compile(r"^\d{10}(\d{3})?$")
ID_SEGMENT = re.compile(r"/(?:[0-9a-fA-F-]{8,}|[0-9]+|[a-z0-9-]{8,}[0-9][a-z0-9-]*)(?=/|$)")
VOLATILE_HEADERS = {"date", "x-request-id", "x-correlation-id", "traceparent", "tracestate", "x-amzn-trace-id",
                    "etag", "last-modified", "expires", "age", "set-cookie"}
PG_EPOCH = datetime(2000, 1, 1, tzinfo=timezone.utc)

def section(text, name):
    m = re.search(r"### " + name + r" ###\s*(.*?)(?=\n### |\Z)", text, re.S)
    return m.group(1) if m else ""

def parse_message(block):
    """First fence: start line plus headers. Second fence, when present: the body."""
    fences = fence_re.findall(block)
    if not fences:
        return "", {}, None, None
    lines = fences[0].splitlines()
    start = lines[0] if lines else ""
    headers = {}
    for line in lines[1:]:
        key, sep, value = line.partition(":")
        if not sep:
            continue
        key = key.strip()
        value = value.strip().replace("\\,", ",")
        headers[key] = "<redacted>" if key.lower() in SECRET_HEADERS else value
    raw = fences[1] if len(fences) > 1 else None
    body = raw
    if raw is not None:
        try:
            body = json.loads(raw)
        except ValueError:
            pass
    return start, headers, body, raw

def value_kind(value):
    if not isinstance(value, str):
        return None
    if UUID_RE.match(value):
        return "uuid"
    if TIMESTAMP_RE.match(value):
        return "timestamp"
    if TOKEN_RE.match(value):
        return "token"
    return None

def volatile_values(value, path="$"):
    """(path, kind, value) for every volatile leaf. Array indices collapse to
    [*] so a 40-row list reports each field once."""
    found = []
    if isinstance(value, dict):
        for k, v in value.items():
            found += volatile_values(v, f"{path}.{k}")
    elif isinstance(value, list):
        for v in value:
            found += volatile_values(v, f"{path}[*]")
    else:
        kind = value_kind(value)
        if kind:
            found.append((path, kind, value))
    return found

def normalized(value):
    """The body with volatile values replaced by their kind, so two exchanges that
    differ only in IDs and timestamps count as the same case."""
    if isinstance(value, dict):
        return {k: normalized(v) for k, v in value.items()}
    if isinstance(value, list):
        return [normalized(v) for v in value]
    return f"<{value_kind(value)}>" if value_kind(value) else value

ISO_PARTS = re.compile(r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?)(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})?$")

def parse_ts(s):
    """Recordings made on Linux carry nanoseconds, and fromisoformat before
    Python 3.11 takes only 3 or 6 fractional digits, so the fraction is cut to
    microseconds first."""
    m = ISO_PARTS.match(str(s or "").strip())
    if not m:
        return None
    base, frac, zone = m.groups()
    text = base + (f".{(frac + '000000')[:6]}" if frac else "")
    if zone:
        text += "+00:00" if zone == "Z" else (zone if ":" in zone else f"{zone[:3]}:{zone[3:]}")
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None

def duration_of(rr):
    try:
        return timedelta(milliseconds=float(rr.get("duration") or 0))
    except (TypeError, ValueError):
        return timedelta(0)

# --- Postgres value decoding -------------------------------------------------

def raw_bytes(v):
    if "asBytes" in v:
        return base64.b64decode(v["asBytes"])
    s = v.get("asString", "")
    try:
        return s.encode("latin-1")
    except UnicodeEncodeError:
        return None

def pg_binary(oid, b):
    if b is None:
        return None
    try:
        if oid == 16:
            return b != b"\x00"
        if oid == 21:
            return struct.unpack(">h", b)[0]
        if oid == 23 or oid == 26:
            return struct.unpack(">i", b)[0]
        if oid == 20:
            return struct.unpack(">q", b)[0]
        if oid == 700:
            return struct.unpack(">f", b)[0]
        if oid == 701:
            return struct.unpack(">d", b)[0]
        if oid == 2950:
            return str(uuid.UUID(bytes=b))
        if oid in (1114, 1184):
            ts = PG_EPOCH + timedelta(microseconds=struct.unpack(">q", b)[0])
            return ts.isoformat().replace("+00:00", "Z") if oid == 1184 else ts.replace(tzinfo=None).isoformat()
        if oid == 1082:
            return (PG_EPOCH + timedelta(days=struct.unpack(">i", b)[0])).date().isoformat()
        if oid == 3802 and b[:1] == b"\x01":
            return json.loads(b[1:].decode())
        if oid in (25, 1043, 1042, 19, 114):
            return b.decode()
    except (struct.error, ValueError, UnicodeDecodeError):
        pass
    return {"undecoded": base64.b64encode(b).decode(), "typeOid": oid}

def pg_value(v, oid, fmt):
    if v is None or v.get("isNull"):
        return None
    if fmt == 1:
        return pg_binary(oid, raw_bytes(v))
    text = v.get("asString")
    if text is None:
        text = (raw_bytes(v) or b"").decode(errors="replace")
    if oid in (20, 21, 23, 26):
        try:
            return int(text)
        except ValueError:
            return text
    if oid == 16:
        return text in ("t", "true")
    return text

def format_codes(codes, n):
    if not codes:
        return [0] * n
    if len(codes) == 1:
        return codes * n
    return list(codes) + [0] * (n - len(codes))

def decode_postgres(rr):
    """{sql, params, rows, tag} for statements that carry SQL and results;
    None for protocol bookkeeping (Prepare, Describe, Bind, Startup)."""
    pg = rr.get("postgres") or {}
    req, res = pg.get("request") or {}, pg.get("response") or {}
    if "execute" in req:
        bind = req["execute"].get("bindRequest") or {}
        parse = bind.get("parseRequest") or {}
        sql = parse.get("query") or rr.get("location") or ""
        param_oids = parse.get("describedParameterOids") or []
        params = bind.get("parameters") or []
        pcodes = format_codes(bind.get("parameterFormatCodes"), len(params))
        decoded_params = [pg_value(p, param_oids[i] if i < len(param_oids) else 25, pcodes[i]) for i, p in enumerate(params)]
        fields = ((parse.get("describedRow") or {}).get("fields")) or []
        rcodes = format_codes(bind.get("resultFormatCodes"), len(fields))
        messages = (res.get("execute") or {}).get("messages") or []
    elif "query" in req:
        sql = (req["query"] or {}).get("query") or rr.get("location") or ""
        decoded_params, fields, rcodes = [], [], []
        messages = (res.get("query") or {}).get("messages") or []
    else:
        return None
    rows, tag = [], None
    for m in messages:
        if "rowDescription" in m:
            fields = (m["rowDescription"] or {}).get("fields") or []
            rcodes = [f.get("format", 0) for f in fields]
        elif "dataRow" in m:
            values = (m["dataRow"] or {}).get("values") or []
            rows.append({
                (fields[i].get("name") if i < len(fields) else f"col{i}"):
                    pg_value(v, fields[i].get("dataTypeOid") if i < len(fields) else 25, rcodes[i] if i < len(rcodes) else 0)
                for i, v in enumerate(values)
            })
        elif "complete" in m:
            tag = (m["complete"] or {}).get("tag")
        elif "error" in m or "errorResponse" in m:
            tag = "ERROR"
    entry = {"sql": sql}
    if decoded_params:
        entry["params"] = decoded_params
    if rows:
        entry["rows"] = rows
    entry["tag"] = tag or rr.get("status")
    return entry

# --- read the recording --------------------------------------------------------

inbound, outbound, skipped_json = [], [], 0
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.suffix not in {".md", ".json"}:
        continue
    text = path.read_text(errors="ignore")
    if path.suffix == ".json":
        try:
            rr = json.loads(text)
        except ValueError:
            continue
        text = None
    else:
        m = internal_re.search(text)
        if not m:
            continue
        try:
            rr = json.loads(m.group(1))
        except ValueError:
            continue
    if not isinstance(rr, dict):
        continue
    if rr.get("direction") == "IN":
        if text is None:
            if rr.get("http"):
                skipped_json += 1
            continue
        inbound.append((path, rr, text))
    elif rr.get("direction") == "OUT":
        outbound.append((path, rr, text, parse_ts(rr.get("ts"))))

if skipped_json:
    print(f"select-cases: {skipped_json} inbound HTTP pairs are JSON files; run "
          f"'proxymock files convert --in {root}' to include them", file=sys.stderr)
if not inbound:
    print(f"select-cases: no inbound HTTP or gRPC RRPairs under {root}", file=sys.stderr)
    sys.exit(1)

def service_of(rr):
    host = ((rr.get("http") or {}).get("req") or {}).get("host", "")
    return rr.get("service") or host or "unknown"

def endpoint_of(rr):
    req = (rr.get("http") or {}).get("req") or {}
    method = req.get("method") or str(rr.get("command") or "?").split()[0]
    uri = req.get("uri") or req.get("url") or rr.get("location") or ""
    path_part, _, query = uri.partition("?")
    norm = ID_SEGMENT.sub("/{id}", path_part)
    if query:
        keys = sorted({q.split("=", 1)[0] for q in query.split("&") if q})
        norm += "?" + "&".join(f"{k}={{v}}" for k in keys)
    status = ((rr.get("http") or {}).get("res") or {}).get("statusCode") or rr.get("status")
    return f"{method} {norm}", status

by_service = defaultdict(list)
for item in inbound:
    by_service[service_of(item[1])].append(item)

if list_only:
    for svc in sorted(by_service):
        print(f"{svc}: {len(by_service[svc])} inbound requests")
        counts = defaultdict(int)
        for _, rr, _ in by_service[svc]:
            counts[endpoint_of(rr)] += 1
        for (endpoint, status), n in sorted(counts.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))):
            print(f"  {endpoint} -> {status}  x{n}")
    sys.exit(0)

if not want_service:
    if len(by_service) > 1:
        print("select-cases: the recording holds several inbound services; pass --service with one of: "
              + ", ".join(sorted(by_service)), file=sys.stderr)
        sys.exit(2)
    want_service = next(iter(by_service))
if want_service not in by_service:
    print(f"select-cases: no inbound service named {want_service!r}; found: " + ", ".join(sorted(by_service)), file=sys.stderr)
    sys.exit(2)

# Every inbound request's own span, across all services. The next request's
# start is where this request's dependency calls stop, and a span that meets
# another one means calls cannot be told apart by time.
spans = sorted(
    (start, start + duration_of(rr), id(rr))
    for start, rr in ((parse_ts(rr.get("ts")), rr) for _, rr, _ in inbound) if start)
overlaps, next_start, max_end = {}, {}, None
for i, (start, end, key) in enumerate(spans):
    after = spans[i + 1][0] if i + 1 < len(spans) else None
    next_start[key] = after
    # Durations are whole milliseconds, so spans that touch within one are
    # back-to-back, not concurrent.
    overlaps[key] = (max_end is not None and max_end - TICK > start) or (after is not None and after < end - TICK)
    max_end = end if max_end is None else max(max_end, end)

def window_of(rr):
    start = parse_ts(rr.get("ts"))
    if not start:
        return None, None, True
    end = start + duration_of(rr) + TAIL
    if next_start.get(id(rr)):
        end = min(end, next_start[id(rr)])
    return start, end, overlaps.get(id(rr), True)

def http_call(path, rr, text):
    req = (rr.get("http") or {}).get("req") or {}
    uri = req.get("uri") or req.get("url") or ""
    split = urlsplit(uri)
    query = dict(parse_qsl(split.query, keep_blank_values=True))
    call = {
        "protocol": rr.get("l7protocol") or "http",
        "host": req.get("host", ""),
        "method": req.get("method", ""),
        "path": split.path or uri,
        "status": ((rr.get("http") or {}).get("res") or {}).get("statusCode") or rr.get("status"),
        "file": str(path),
    }
    if query:
        call["query"] = query
        volatile = sorted(k for k, v in query.items() if value_kind(v) or EPOCH_RE.match(v))
        if volatile:
            call["volatileQuery"] = volatile
    if text:
        _, req_headers, _, _ = parse_message(section(text, "REQUEST"))
        vh = sorted(h for h in req_headers if h.lower() in VOLATILE_HEADERS)
        if vh:
            call["volatileHeaders"] = vh
        _, res_headers, body, raw = parse_message(section(text, "RESPONSE"))
        content_type = next((v for k, v in res_headers.items() if k.lower() == "content-type"), None)
        if content_type:
            call["responseContentType"] = content_type
        if raw is not None:
            call["_returned"] = body
            if len(raw) <= INLINE_BODY_LIMIT or not bodies_dir:
                call["responseBody"] = body
            else:
                bodies_dir.mkdir(parents=True, exist_ok=True)
                ext = ".json" if not isinstance(body, str) else ".txt"
                body_file = bodies_dir / (hashlib.sha256(raw.encode()).hexdigest()[:12] + ext)
                body_file.write_text(raw)
                call["responseBodyFile"] = str(body_file)
    return call

def dependency_calls(rr):
    start, end, overlapped = window_of(rr)
    if not start:
        # No usable timestamp: say the calls are unknown rather than none.
        return [], True
    calls = []
    for path, out_rr, text, ts in outbound:
        if not ts or not (start <= ts < end):
            continue
        if out_rr.get("postgres"):
            decoded = decode_postgres(out_rr)
            if decoded:
                calls.append({"protocol": "postgres", "file": str(path), **decoded})
        elif out_rr.get("http"):
            calls.append(http_call(path, out_rr, text))
        else:
            calls.append({
                "protocol": out_rr.get("l7protocol") or "",
                "operation": str(out_rr.get("location") or out_rr.get("command") or "")[:300],
                "status": out_rr.get("status"),
                "file": str(path),
            })
    calls.sort(key=lambda c: c["file"])
    return calls, overlapped

def returned_values(calls):
    """Strings the dependencies returned (result rows, response bodies), not
    what the service sent them: an ID the service generated and then wrote to
    the database is still the service's own."""
    found = []
    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, str):
            found.append(v)
    for call in calls:
        walk(call.get("rows"))
        walk(call.get("_returned"))
    return found

def sent_to(value, calls):
    """The first dependency call a service-made value was also sent to, such as
    a generated ID written to the database: assert the two are equal."""
    for call in calls:
        for param in call.get("params") or []:
            if isinstance(param, str) and param.lower() == value.lower():
                return call.get("sql") or call.get("path")
        if value in json.dumps(call.get("query") or {}):
            return call.get("path")
    return None

def mark_volatile_params(calls, request_text, response_text):
    """Flags SQL parameters that change between runs and says where each came
    from, so the test knows which to pin and which to compare to the request."""
    for call in calls:
        flagged = []
        for i, param in enumerate(call.get("params") or []):
            kind = value_kind(param)
            if not kind:
                continue
            if param.lower() in request_text.lower():
                src = "request"
            elif param.lower() in response_text.lower():
                src = "response"
            else:
                src = "generated"
            flagged.append({"index": i + 1, "kind": kind, "source": src})
        if flagged:
            call["volatileParams"] = flagged

def same_instant(a, b):
    ta, tb = parse_ts(a), parse_ts(b)
    if not ta or not tb or (ta.tzinfo is None) != (tb.tzinfo is None):
        return False
    return abs(ta - tb) < timedelta(milliseconds=1)

def source_of(value, kind, request_text, returned):
    if value.lower() in request_text.lower():
        return "request"
    if kind == "timestamp":
        if any(same_instant(value, r) for r in returned):
            return "dependency"
    elif any(value.lower() == r.lower() for r in returned):
        return "dependency"
    return "generated"

groups = defaultdict(list)
for item in by_service[want_service]:
    groups[endpoint_of(item[1])].append(item)

endpoints, any_overlap = [], False
for (endpoint, status), items in sorted(groups.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))):
    cases, seen, distinct = [], set(), 0
    # Requests that ran alone first: their dependency calls are exact.
    items = sorted(items, key=lambda item: window_of(item[1])[2])
    for path, rr, text in items:
        req_line, req_headers, req_body, req_raw = parse_message(section(text, "REQUEST"))
        res_line, res_headers, res_body, _ = parse_message(section(text, "RESPONSE"))
        # Identical requests with different answers (a list that grew) are
        # distinct cases; answers that differ only in IDs and times are not.
        # The group is already one templated endpoint, so the key is the bodies.
        key = hashlib.sha256(json.dumps(
            [normalized(req_body), normalized(res_body)], sort_keys=True, default=str).encode()).hexdigest()
        if key in seen:
            continue
        seen.add(key)
        distinct += 1
        if len(cases) >= per:
            continue
        method, _, rest = req_line.partition(" ")
        target = urlsplit(rest.rsplit(" ", 1)[0])
        calls, overlapped = dependency_calls(rr)
        any_overlap |= overlapped
        request_text = (target.path or "") + "?" + (target.query or "") + (req_raw or "")
        returned = returned_values(calls)
        volatile, seen_paths = [], set()
        for vpath, kind, value in volatile_values(res_body):
            src = source_of(value, kind, request_text, returned)
            if (vpath, src) in seen_paths:
                continue
            seen_paths.add((vpath, src))
            entry = {"path": vpath, "kind": kind, "source": src}
            if src == "generated":
                target_call = sent_to(value, calls)
                if target_call:
                    entry["alsoSentTo"] = target_call
            volatile.append(entry)
        mark_volatile_params(calls, request_text, json.dumps(res_body, default=str))
        for call in calls:
            call.pop("_returned", None)
        response_volatile_headers = sorted(h for h in res_headers if h.lower() in VOLATILE_HEADERS)
        case = {
            "file": str(path),
            "ts": rr.get("ts"),
            "request": {
                "method": method,
                "path": target.path + (f"?{target.query}" if target.query else ""),
                "headers": req_headers,
                "body": req_body,
                "rawBody": req_raw,
            },
            "response": {"status": status, "headers": res_headers, "volatileHeaders": response_volatile_headers, "body": res_body},
            "volatile": volatile,
            "dependencies": calls,
        }
        if overlapped:
            case["dependenciesApproximate"] = True
        cases.append(case)
    endpoints.append({"endpoint": endpoint, "status": status, "recorded": len(items), "distinct": distinct, "cases": cases})

doc = {"recording": str(root), "service": want_service, "endpoints": endpoints}
if any_overlap:
    doc["note"] = ("some requests overlapped in time, so their dependency calls may include calls "
                   "made for a concurrent request (marked dependenciesApproximate)")
text = json.dumps(doc, indent=2, default=str) + "\n"
if out:
    pathlib.Path(out).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(out).write_text(text)
    print(f"select-cases: {sum(len(e['cases']) for e in endpoints)} cases over {len(endpoints)} endpoints written to {out}", file=sys.stderr)
else:
    sys.stdout.write(text)
PY

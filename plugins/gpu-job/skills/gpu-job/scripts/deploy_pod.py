#!/usr/bin/env python3
"""gpu-job: deploy a disposable GPU pod (RunPod backend) and wait for direct SSH.

Config: ~/.config/gpu-job/env (KEY=VAL lines, written by gpu_job_init.sh); process env
overrides. Required: RUNPOD_API_KEY (or API_KEY_ENV=<var name> to read another), SSH_PUBLIC_KEY. Knobs (env): GPU_TYPES
(comma list, e.g. "NVIDIA L40S,NVIDIA A100 80GB PCIe" — every listed type is offered to RunPod
together via gpuTypePriority=availability, so ANY one of them satisfies the request; wins over
GPU_TYPE), GPU_TYPE (single id, back-compat one-item form of GPU_TYPES), GPU_COUNT (1), DISK_GB
(220), POD_NAME ("gpu-job"), POD_NAME_PREFIX ("" —
prepended to the pod name for shared-account dashboard visibility, e.g. "anton-"), IMAGE, TEMPLATE_ID,
DATA_CENTERS (comma list, or "all" = every pod-creatable DC; overrides tiered retry), VOLUME_ID
(network volume; requires DATA_CENTERS), RETRY_MINUTES (keep retrying ~3-min cycles until
stock appears or the deadline passes — scarce multi-GPU stock can take an hour; default 0 =
single pass), PASS_ENV (comma list of extra var names to inject into the pod's env).
Neither GPU_TYPES nor GPU_TYPE set -> defaults to an ample, non-premium SKU list (L40S / A100 80GB
PCIe / A40 / RTX 4090-class), never a single scarce premium card like H200 (#351); state the job's
actual hardware need explicitly via GPU_TYPES/GPU_TYPE instead of relying on this fallback.
If RCLONE_CONF_B64 is set (by init, from your rclone.conf remote), it is injected so the
pod can read/write your artifact store.

Prints POD_ID / SSH / COST_PER_HR. Region coverage is derived LIVE from RunPod's pod-creatable
DC set (dataCenters listed=true) and searched in geographic preference tiers (US-west→central→
east→EU→rest-of-world); `--selftest` runs the offline region-selection unit check.
Battle-tested lineage: extracted from a research lab's deploy after three independent
hand-rolled variants in one day; the 220GB default exists because 30GB kills any pod
that downloads a large base model.
"""
import json, os, sys, time, urllib.request, urllib.error

CFG = os.path.expanduser("~/.config/gpu-job/env")
_SELFTEST = "--selftest" in sys.argv  # offline unit check — must not require RunPod creds

# The script is ENV-driven: a real deploy takes NO command-line args. Classify help/unknown-arg
# invocations EARLY — before the required-cred reads below — so they neither require config nor reach
# deploy(). A `--help` or a typo must never spend money (#264).
_USAGE = """\
deploy_pod.py — deploy a disposable RunPod GPU pod and wait for direct SSH.

WARNING: a bare invocation (no args) DEPLOYS A REAL, BILLED GPU POD.

Configured entirely by environment variables in ~/.config/gpu-job/env (API_KEY_ENV / RUNPOD_API_KEY,
SSH_PUBLIC_KEY, GPU / region / retry settings, ...); it takes NO positional arguments.
Recognized flags:
  --help, -h   show this help and exit (no deploy)
  --selftest   offline self-check, no RunPod creds required (no deploy)
"""
_ARGV = sys.argv[1:]
_HELP = ("-h" in _ARGV) or ("--help" in _ARGV)
# anything that is not a recognized flag -> refuse (fail-closed; kills the typo-deploys hazard)
_BADARGS = [a for a in _ARGV if a not in ("--selftest", "--help", "-h")]
_NO_DEPLOY = _SELFTEST or _HELP or bool(_BADARGS)  # none of these may require creds at import


def env(key, default=None, required=False):
    v = os.environ.get(key)
    if v:
        return v
    try:
        for line in open(CFG):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    if required and default is None:
        raise SystemExit(f"missing {key} (set it in {CFG} via gpu_job_init.sh, or in env)")
    return default


# API_KEY_ENV names the variable holding the key (default RUNPOD_API_KEY). The indirection
# exists for multi-account instances: a sourced .env exporting RUNPOD_API_KEY would otherwise
# silently override the config and deploy to the wrong account (real incident: a research pod
# billed to a personal account, and teardown-by-the-other-key 404'd, masquerading as deleted).
KEY_NAME = env("API_KEY_ENV", default="RUNPOD_API_KEY")
KEY = env(KEY_NAME, required=not _NO_DEPLOY)        # selftest/help/bad-arg are offline: don't require creds to import
PUBLIC_KEY = env("SSH_PUBLIC_KEY", required=not _NO_DEPLOY)

# Region coverage is derived LIVE from RunPod's `dataCenters(listed=true)` set (the pod-creatable
# subset) — a hand-maintained list rots (it drifts out of date AND accretes now-unlisted ids that
# schema-reject a batch). `_FALLBACK_DCS` is a BACKSTOP only, used iff the live query fails; it is
# the `listed: true` set as of 2026-06-17 and is never sent as one all-or-nothing batch (see
# select_tiers), so a stale id can only no-go its own small bucket.
_FALLBACK_DCS = [
    "US-CA-2", "US-WA-1", "US-TX-3", "US-TX-4", "US-KS-2", "US-IL-1",
    "US-MO-1", "US-MO-2", "US-NE-1", "US-GA-2", "US-NC-1", "US-NC-2", "US-MD-1",
    "EU-RO-1", "EU-CZ-1", "EU-NL-1", "EU-FR-1", "EU-SE-1",
    "EUR-IS-1", "EUR-IS-2", "EUR-IS-3", "EUR-IS-4", "EUR-NO-1", "EUR-NO-2",
    "CA-MTL-1", "CA-MTL-3", "CA-MTL-4", "AP-IN-1", "AP-JP-1", "OC-AU-1",
]

# Geographic preference: ordered (label, prefix-tuple). A DC joins the FIRST tier whose prefix it
# matches; anything unmatched falls into a final catch-all tier — so a brand-new RunPod region prefix
# is still searched (just last), never silently dropped. Preserves the prior US-west -> central ->
# east -> EU order and adds rest-of-world (CA/AP/OC/…) so the default path reaches it too.
_TIER_RULES = [
    ("us-west",    ("US-WA", "US-CA", "US-OR", "US-NV")),
    ("us-central", ("US-TX", "US-KS", "US-IL", "US-MO", "US-NE", "US-MN", "US-ND", "US-SD")),
    ("us-east",    ("US-GA", "US-NC", "US-MD", "US-DE", "US-PA", "US-VA", "US-NY")),
    ("eu",         ("EU-", "EUR-")),
    ("row",        ("CA-", "AP-", "OC-", "SEA-", "SA-", "ME-", "AF-")),
]

# #351: the prior single-SKU default (H200) is a chronically scarce, premium card — a generic serving/
# training job needs any card with enough VRAM, and RunPod has ample supply of these ≥24GB cards at a
# fraction of the price. Used only when the caller states no hardware need at all (neither GPU_TYPES nor
# GPU_TYPE); explicitly stating the need is always preferred over relying on this fallback.
_DEFAULT_GPU_TYPES = ["NVIDIA L40S", "NVIDIA A100 80GB PCIe", "NVIDIA A40", "NVIDIA GeForce RTX 4090"]


def resolve_gpu_types(types_csv, type_single):
    """Pure: (GPU_TYPES csv or None, GPU_TYPE single id or None) -> ordered GPU type id candidate list
    sent together as one gpuTypeIds batch (gpuTypePriority=availability picks whichever is available,
    the same pattern dataCenterIds/dataCenterPriority already uses for DCs). GPU_TYPES wins when set;
    GPU_TYPE is the one-item back-compat form; neither set falls back to _DEFAULT_GPU_TYPES rather than
    a single scarce premium SKU (#351). A GPU_TYPES value that parses to no usable entries (e.g. "," or
    " ") is a misconfiguration, not "no preference" — raises rather than silently sending an empty
    gpuTypeIds batch to the API."""
    if types_csv:
        parsed = [t.strip() for t in types_csv.split(",") if t.strip()]
        if not parsed:
            raise SystemExit(f"GPU_TYPES={types_csv!r} has no usable entries after parsing")
        return parsed
    if type_single:
        return [type_single]
    return list(_DEFAULT_GPU_TYPES)


def gpu_types():
    return resolve_gpu_types(env("GPU_TYPES"), env("GPU_TYPE"))


def listed_dcs(payload):
    """Pure: pod-creatable (listed=true) DC ids from a GraphQL `dataCenters{id listed}` payload, sorted."""
    dcs = (payload or {}).get("data", {}).get("dataCenters") or []
    return sorted({d["id"] for d in dcs if d.get("id") and d.get("listed")})


def tiered(dcs):
    """Pure: bucket DC ids into geographic preference tiers; unmatched prefixes -> a final catch-all
    tier. Returns the non-empty id-lists in preference order (every input id appears exactly once)."""
    buckets = [[] for _ in _TIER_RULES]
    catch = []
    for dc in dcs:
        for i, (_, prefixes) in enumerate(_TIER_RULES):
            if any(dc == p or dc.startswith(p) for p in prefixes):
                buckets[i].append(dc)
                break
        else:
            catch.append(dc)
    tiers = [b for b in buckets if b]
    if catch:
        tiers.append(catch)
    return tiers


def select_tiers(mode, dcs, live):
    """Pure: (DATA_CENTERS mode, creatable dcs, live?) -> ordered list of dataCenterId batches to try.
    - mode == "all": one batch of every live id (valid enum, safe) — or, if only the static fallback is
      available (live=False), the geographic buckets, so a possibly-stale id can't poison the whole batch.
    - mode == "<csv>": the operator's explicit list, verbatim (one batch).
    - mode falsy (default): geographic preference tiers."""
    if mode == "all":
        return [list(dcs)] if live else tiered(dcs)
    if mode:
        return [[d.strip() for d in mode.split(",") if d.strip()]]
    return tiered(dcs)


def creatable_dcs():
    """(ids, live): live `listed=true` DC set from RunPod GraphQL, or the static fallback if it fails."""
    try:
        ids = listed_dcs(gql("query { dataCenters { id listed } }"))
        if ids:
            return ids, True
        print("[deploy] live dataCenters query returned none; using static fallback list", flush=True)
    except Exception as e:
        print(f"[deploy] live dataCenters query failed ({e}); using static fallback list", flush=True)
    return list(_FALLBACK_DCS), False


def post_rest(path, body):
    req = urllib.request.Request("https://rest.runpod.io/v1" + path,
                                 data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:400]


def gql(query):
    req = urllib.request.Request(f"https://api.runpod.io/graphql?api_key={KEY}",
                                 data=json.dumps({"query": query}).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "curl/8.5.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


# --- pod lease (the #54 child-2 deletion-scoped lease; written across deploy so a model-free reaper
#     can safely delete an abandoned pod). Wraps pod_lease.sh so the atomic-write + lock semantics live
#     in one product implementation. GPU_JOB_LEASE_DISABLE=1 turns the wiring off (a standalone caller
#     who doesn't want a lease registry); the reaper simply has nothing to read for that pod.
import subprocess

# realpath (not abspath) so sibling helpers resolve to the CANONICAL scripts dir even when this file is
# invoked through a box-side symlink (#297): abspath keeps the symlink path, realpath follows it.
_LEASE_SH = os.path.join(os.path.dirname(os.path.realpath(__file__)), "pod_lease.sh")
_LEASE_ON = env("GPU_JOB_LEASE_DISABLE", "") not in ("1", "true", "yes")


def lease(*args, check=True):
    """Run pod_lease.sh <args>; return stripped stdout (or None if leasing is disabled)."""
    if not _LEASE_ON:
        return None
    r = subprocess.run(["bash", _LEASE_SH, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"pod_lease.sh {args[0]} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def delete_pod_now(pod_id):
    """Best-effort synchronous DELETE with the deploying key (the write-failure fail-closed path)."""
    req = urllib.request.Request(f"https://rest.runpod.io/v1/pods/{pod_id}", method="DELETE",
                                 headers={"Authorization": f"Bearer {KEY}", "User-Agent": "gpu-job"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status in (200, 201, 202, 204)   # same accepted set as the reaper/teardown contract
    except urllib.error.HTTPError as e:
        # a 404 means the pod is already gone (an accepted outcome for "make it not exist")
        if e.code == 404:
            return True
        print(f"[lease] emergency DELETE of {pod_id} -> HTTP {e.code}", flush=True)
        return False
    except Exception as e:
        print(f"[lease] emergency DELETE of {pod_id} errored: {e}", flush=True)
        return False


# --- mid-create abort cleanup (#278). deploy is non-atomic: POST /pods starts BILLING, then wait_ssh
#     polls ~30-90s for readiness. A kill in that window (a `timeout` wrapper's SIGTERM, Ctrl-C, a host
#     time limit) otherwise leaves the just-created pod billing until the reaper reaps it at the SHORT
#     intent-lease expiry. This trap DELETEs the un-confirmed pod immediately on a catchable signal.
#     (The untrappable SIGKILL/hard-timeout case is already bounded by that short intent lease.)
import signal

_INFLIGHT = {"pid": None, "nonce": None}  # set the instant the create 201 returns; cleared once enriched


def _abort_cleanup(signum, _frame):
    pid = _INFLIGHT.get("pid")
    if pid:
        print(f"[deploy] signal {signum} during acquire — deleting un-confirmed pod {pid} "
              f"(billing; fail-closed)", flush=True)
        gone = delete_pod_now(pid)
        n = _INFLIGHT.get("nonce")
        if n and _LEASE_ON:
            try:
                lease("emergency", n, str(pid), check=False)  # mark reapable if the DELETE didn't land
                if gone:
                    lease("mark-deleted", n, check=False)     # verified gone -> reaper closes, doesn't loop
            except Exception:
                pass
    raise SystemExit(130 if signum == signal.SIGINT else 143)


def pod_env():
    e = {"PUBLIC_KEY": PUBLIC_KEY}
    if env("RCLONE_CONF_B64"):
        e["RCLONE_CONF_B64"] = env("RCLONE_CONF_B64")
    if env("RCLONE_REMOTE") and env("RCLONE_REMOTE") != "skip":
        e["RCLONE_REMOTE"] = env("RCLONE_REMOTE")
    for var in (env("PASS_ENV", "") or "").split(","):
        var = var.strip()
        if var and env(var):
            e[var] = env(var)
    return e


def deploy(nonce=None):
    # When leasing is on, the pod NAME is the lease nonce (gpujob-<hex>) so the reaper can match an
    # otherwise-unknown pod to its pending intent. POD_NAME is honored only when leasing is disabled.
    # POD_NAME_PREFIX (e.g. "anton-" on a shared account) is prepended for dashboard visibility. The same
    # resolved prefix is passed explicitly to the intent (--name-prefix), which records the EXACT expected
    # name (prefix+nonce); the reaper's find-nonce exact-matches it — deletion authority stays exact-whole-string.
    pod_name = env("POD_NAME_PREFIX", "") + (nonce if (nonce and _LEASE_ON) else env("POD_NAME", "gpu-job"))
    types = gpu_types()
    print(f"[deploy] GPU type(s): {types} "
          f"(source={'GPU_TYPES' if env('GPU_TYPES') else 'GPU_TYPE' if env('GPU_TYPE') else 'default'})",
          flush=True)
    base = {"cloudType": "SECURE",
            "gpuCount": int(env("GPU_COUNT", "1")),
            "gpuTypeIds": types,
            "gpuTypePriority": "availability",
            "containerDiskInGb": int(env("DISK_GB", "220")),
            "volumeInGb": 0, "volumeMountPath": "/workspace",
            "imageName": env("IMAGE", "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404"),
            "templateId": env("TEMPLATE_ID", "runpod-torch-v280"),
            "ports": ["22/tcp"], "dataCenterPriority": "availability",
            "name": pod_name,
            "env": pod_env()}
    if env("VOLUME_ID"):
        base["networkVolumeId"] = env("VOLUME_ID")
        del base["volumeInGb"]
    mode = env("DATA_CENTERS")
    if mode and mode != "all":
        tiers = select_tiers(mode, None, True)                  # explicit csv: verbatim, no DC lookup
    elif env("VOLUME_ID") and not mode:
        raise SystemExit("VOLUME_ID set but no DATA_CENTERS — a network volume is region-locked; pass its region")
    else:                                                       # mode == "all" or unset (default)
        dcs, live = creatable_dcs()
        tiers = select_tiers(mode, dcs, live)
        print(f"[deploy] region set: {sum(len(t) for t in tiers)} DC(s) in {len(tiers)} tier(s) "
              f"(source={'live' if live else 'fallback'}, mode={mode or 'default'})", flush=True)
    deadline = time.time() + 60 * int(env("RETRY_MINUTES", "0"))
    attempt = 0
    while True:
        attempt += 1
        for tier in tiers:
            st, resp = post_rest("/pods", dict(base, dataCenterIds=tier))
            print(f"[deploy] attempt {attempt} tier {tier[:2]}... -> HTTP {st}", flush=True)
            if st in (200, 201):
                pid = resp.get("id") or resp.get("podId")
                # From this instant the pod is BILLING but not yet confirmed — arm the abort trap so a
                # kill during the readiness poll deletes it (#278). Cleared once fully enriched.
                _INFLIGHT["pid"] = pid; _INFLIGHT["nonce"] = nonce
                print(f"[deploy] OK pod={pid} dc={resp.get('machine',{}).get('dataCenterId','?')} "
                      f"costPerHr={resp.get('costPerHr','?')}", flush=True)
                # PROVISIONAL: bind the real pod id to the intent. WRITE-FAILURE → fail CLOSED: the pod
                # is already billing, so synchronously DELETE it with the deploying key (or leave the
                # emergency record) rather than a silent un-leased orphan.
                if nonce and _LEASE_ON:
                    try:
                        lease("provisional", nonce, str(pid))
                    except Exception as e:
                        print(f"[lease] provisional write FAILED for {pid} ({e}) — failing closed: "
                              f"DELETE the un-leased pod", flush=True)
                        gone = delete_pod_now(pid)
                        try:
                            # emergency record: bind the discovered id + force expiry NOW so the reaper
                            # reaps it if the synchronous DELETE above didn't (the one place to look).
                            lease("emergency", nonce, str(pid), check=False)
                            # If our synchronous DELETE was accepted, persist the marker (round-11 Finding
                            # 3) so a later reaper sweep — whose fresh DELETE would 404 (already gone) —
                            # can still CLOSE on verified-gone instead of looping on the emergency lease.
                            if gone:
                                lease("mark-deleted", nonce, check=False)
                        except Exception:
                            pass
                        raise SystemExit(f"[deploy] provisional lease write failed; pod {pid} "
                                         + ("DELETED (fail-closed)" if gone else
                                            f"could NOT be deleted — REAP {pid} MANUALLY (emergency lease {nonce})"))
                return pid
            print(f"  no go: {str(resp)[:160]}", flush=True)
        if time.time() >= deadline:
            # #351: "no stock" for a single requested SKU reads as false platform-wide scarcity — say so
            # explicitly so an executor doesn't misreport it as "RunPod has no GPUs."
            narrow = (f" — this asked for exactly one GPU type ({types[0]!r}); that is NOT evidence "
                      f"RunPod is out of GPUs, only that this one SKU is scarce right now — set "
                      f"GPU_TYPES to a comma list of acceptable SKUs before concluding no capacity"
                      if len(types) == 1 else "")
            raise SystemExit("[deploy] no stock in any tier"
                             + (f" after {attempt} attempts" if attempt > 1 else "")
                             + " (set RETRY_MINUTES=N to keep trying)" + narrow)
        print(f"[deploy] no stock; retrying in 3 min "
              f"({int((deadline - time.time()) / 60)} min left)", flush=True)
        time.sleep(180)


def wait_ssh(pid):
    for i in range(40):
        time.sleep(8)
        try:
            p = gql('query { pod(input:{podId:"%s"}) { desiredStatus costPerHr runtime '
                    '{ uptimeInSeconds ports { ip publicPort privatePort type } } } }' % pid)["data"]["pod"]
        except Exception as e:
            print(f"  poll {i}: {e}", flush=True); continue
        rt = (p or {}).get("runtime")
        if rt and rt.get("ports"):
            for port in rt["ports"]:
                if port.get("privatePort") == 22 and port.get("ip"):
                    print(f"[ssh] ready: ip={port['ip']} port={port['publicPort']} "
                          f"costPerHr={p.get('costPerHr')}", flush=True)
                    return port["ip"], port["publicPort"], p.get("costPerHr")
        print(f"  poll {i}: runtime not ready (uptime={(rt or {}).get('uptimeInSeconds')})", flush=True)
    raise SystemExit(f"[ssh] endpoint not ready after ~5min — if uptime>0 with ports None, "
                     f"DELETE pod {pid} and redeploy (known provider failure mode; don't wait it out)")


def _selftest():
    """Offline unit check of the region-selection contract (no network, no pod, no creds)."""
    payload = {"data": {"dataCenters": [
        {"id": "US-WA-1", "listed": True}, {"id": "US-CA-2", "listed": True},
        {"id": "US-TX-3", "listed": True}, {"id": "US-GA-2", "listed": True},
        {"id": "EU-FR-1", "listed": True}, {"id": "AP-JP-1", "listed": True},
        {"id": "CA-MTL-3", "listed": True}, {"id": "ZZ-NEW-1", "listed": True},   # unknown prefix
        {"id": "US-TX-1", "listed": False}, {"id": "EUR-IS-5", "listed": False},  # unlisted -> excluded
    ]}}
    ids = listed_dcs(payload)
    assert "US-TX-1" not in ids and "EUR-IS-5" not in ids, "unlisted DCs must be excluded"
    assert ids == ["AP-JP-1", "CA-MTL-3", "EU-FR-1", "US-CA-2", "US-GA-2", "US-TX-3", "US-WA-1", "ZZ-NEW-1"], ids
    t = tiered(ids)
    assert t[0] == ["US-CA-2", "US-WA-1"], t[0]                  # us-west first, sorted within tier
    assert t[-1] == ["ZZ-NEW-1"], t                              # unknown prefix -> final catch-all, never dropped
    assert sorted(dc for tier in t for dc in tier) == ids, "every listed DC appears exactly once"
    assert select_tiers("all", ids, True) == [list(ids)], "all+live -> one batch of every id"
    assert select_tiers("all", ids, False) == t, "all+fallback -> geographic buckets (blast-radius-limited)"
    assert select_tiers("US-CA-2, EU-FR-1", ids, True) == [["US-CA-2", "EU-FR-1"]], "explicit csv verbatim"
    assert select_tiers(None, ids, True) == t, "default -> tiers"
    assert listed_dcs({}) == [] and tiered([]) == [], "empty payload is safe"
    assert _FALLBACK_DCS and all(d == d.strip() and "-" in d for d in _FALLBACK_DCS), "fallback list well-formed"
    # #351: GPU type resolution — GPU_TYPES (csv) wins, GPU_TYPE is the one-item back-compat form,
    # and neither set falls back to an ample non-premium list, never a single scarce premium SKU.
    assert resolve_gpu_types("NVIDIA L40S, NVIDIA A100 80GB PCIe", None) == \
        ["NVIDIA L40S", "NVIDIA A100 80GB PCIe"], "GPU_TYPES csv parsed and stripped"
    assert resolve_gpu_types(None, "NVIDIA H200") == ["NVIDIA H200"], "GPU_TYPE -> one-item list"
    assert resolve_gpu_types("A,B", "NVIDIA H200") == ["A", "B"], "GPU_TYPES takes priority over GPU_TYPE"
    assert resolve_gpu_types(None, None) == _DEFAULT_GPU_TYPES, "no override -> ample default list"
    assert len(_DEFAULT_GPU_TYPES) > 1 and "NVIDIA H200" not in _DEFAULT_GPU_TYPES, \
        "default must be a multi-SKU, non-premium list, not the old single scarce card"
    try:
        resolve_gpu_types(",", None)
        assert False, "malformed GPU_TYPES (no usable entries) must raise, not send an empty gpuTypeIds batch"
    except SystemExit:
        pass
    print(f"deploy_pod selftest OK: {len(ids)} DCs -> {len(t)} tiers")


def _selftest_cleanup():
    """Offline unit check of the #278 mid-create abort trap (no network, no pod, no creds): an
    in-flight pod is DELETEd on a catchable signal; a confirmed/cleared pod is left alone. Stubs the
    network DELETE + the lease subprocess."""
    global delete_pod_now, lease
    _real_del, _real_lease = delete_pod_now, lease
    deleted = []
    delete_pod_now = lambda pid: (deleted.append(pid) or True)   # noqa: E731 (test stub)
    lease = lambda *a, **k: (deleted and None) or ""             # noqa: E731 (no-op lease in test)
    try:
        _INFLIGHT["pid"] = "pod-x"; _INFLIGHT["nonce"] = "gpujob-abc"
        try:
            _abort_cleanup(signal.SIGTERM, None)
        except SystemExit as e:
            assert e.code == 143, e.code
        assert deleted == ["pod-x"], f"in-flight pod must be deleted on signal, got {deleted}"
        deleted.clear()
        _INFLIGHT["pid"] = None                                  # confirmed / handed off
        try:
            _abort_cleanup(signal.SIGINT, None)
        except SystemExit as e:
            assert e.code == 130, e.code
        assert deleted == [], f"a cleared/confirmed pod must NOT be deleted, got {deleted}"
    finally:
        delete_pod_now, lease = _real_del, _real_lease
        _INFLIGHT["pid"] = None; _INFLIGHT["nonce"] = None
    print("deploy_pod cleanup selftest OK: in-flight pod deleted on signal; confirmed pod left alone")


if __name__ == "__main__":
    if _BADARGS:                    # unrecognized arg: refuse FIRST, never deploy (fail-closed even
        sys.stderr.write(f"deploy_pod.py: unrecognized argument(s): {' '.join(_BADARGS)}\n\n")
        sys.stderr.write(_USAGE)    # alongside --selftest/--help — a typo never slips through)
        raise SystemExit(2)
    if _SELFTEST:
        _selftest(); _selftest_cleanup(); raise SystemExit(0)
    # Install the mid-create abort trap (#278) BEFORE any pod is created, so a kill during deploy/poll
    # deletes the un-confirmed billing pod instead of orphaning it (cleared once the pod is enriched).
    signal.signal(signal.SIGTERM, _abort_cleanup)
    signal.signal(signal.SIGINT, _abort_cleanup)
    if _HELP:                       # --help/-h: print usage, never deploy
        print(_USAGE); raise SystemExit(0)
    # INTENT (pre-deploy): mint the lease BEFORE deploy() so even a created-but-id-never-returned pod
    # is covered (the reaper matches it to the pending intent by nonce and reaps it on the intent
    # expiry). The intent records the KEY REFERENCE the reaper resolves on its own (the API_KEY_ENV var
    # name, not the secret). The intent expiry must cover the WHOLE acquire window — RETRY_MINUTES of
    # deploy retries + wait_ssh (~5min) + a cushion — or a pod created LATE in a long retry loop could
    # be reaped before enrich extends it (code-review Finding 1). enrich resets it to the run's real
    # expiry once SSH is up.
    intent_min = int(env("RETRY_MINUTES", "0")) + 20
    # Pass the EXACT prefix deploy resolved (from the config file + env) into the intent, so the recorded
    # expected_name always matches the pod name even when POD_NAME_PREFIX lives only in ~/.config/gpu-job/env
    # and is not in this process's exported environment for the subprocess to inherit.
    nonce = lease("intent", KEY_NAME, "--expiry-min", str(intent_min),
                  "--name-prefix", env("POD_NAME_PREFIX", "")) if _LEASE_ON else None
    if nonce:
        print(f"[lease] intent {nonce} (key_ref={KEY_NAME}, expiry +{intent_min}min covers the acquire window)", flush=True)
    pid = deploy(nonce)
    ip, port, cost = wait_ssh(pid)
    # ENRICH: SSH endpoint + the run's real expiry (default 12h; a long run REFRESHes via
    # pod_lease.sh refresh, or set GPU_JOB_LEASE_EXPIRY_MIN). FAIL CLOSED (review round-9 Finding 1):
    # if enrich can't durably write the long expiry, the lease keeps only the SHORT intent expiry and
    # the reaper would delete this active run minutes later. A pod with no durable lease is unusable
    # under this contract, so a persistent enrich failure deletes the pod and exits — never hand back a
    # POD_ID whose lease will be reaped out from under it.
    if nonce and _LEASE_ON:
        exp_min = env("GPU_JOB_LEASE_EXPIRY_MIN", "720")
        enriched = False
        for attempt in range(3):
            try:
                lease("enrich", nonce, "--ssh", f"{ip}:{port}", "--expiry-min", exp_min,
                      *(["--cost", str(cost)] if cost is not None else []))
                # verify the long expiry actually landed on disk (not just that the call returned)
                shown = lease("show", nonce, check=False) or ""
                rec = json.loads(shown) if shown.strip().startswith("{") else {}
                if rec.get("state") == "enriched" and isinstance(rec.get("expiry_at"), int) \
                   and rec["expiry_at"] > time.time() + 60:
                    enriched = True
                    print(f"[lease] enriched {nonce} (expiry +{exp_min}min)", flush=True)
                    break
            except Exception as e:
                print(f"[lease] enrich attempt {attempt+1} failed for {nonce} ({e})", flush=True)
            time.sleep(2)
        if not enriched:
            print(f"[lease] enrich could not durably set the run expiry for {nonce} — FAILING CLOSED: "
                  f"deleting pod {pid} (an un-enriched lease would be reaped mid-run)", flush=True)
            gone = delete_pod_now(pid)
            try:
                lease("emergency", nonce, str(pid), check=False)   # mark immediately reapable as backstop
                # If our DELETE was accepted, persist the marker (review post-rebase Finding 1) so a later
                # reaper sweep — whose fresh DELETE would 404 (already gone) — closes on verified-gone
                # instead of retrying this emergency lease forever (parallels the provisional-failure path).
                if gone:
                    lease("mark-deleted", nonce, check=False)
            except Exception:
                pass
            raise SystemExit(f"[deploy] enrich failed; pod {pid} "
                             + ("DELETED (fail-closed)" if gone else
                                f"could NOT be deleted — REAP {pid} MANUALLY (lease {nonce})"))
    # Pod is fully confirmed (SSH up; lease enriched to the long expiry, or leasing disabled). Disarm the
    # abort trap so a later signal (during printing / a caller's own teardown) can't delete a good pod.
    _INFLIGHT["pid"] = None; _INFLIGHT["nonce"] = None
    print(f"\nPOD_ID={pid}")
    if nonce:
        print(f"LEASE_NONCE={nonce}")
    print(f"SSH=ssh -i {env('SSH_KEY_FILE', os.path.expanduser('~/.ssh/id_ed25519'))} -p {port} root@{ip}")
    print(f"COST_PER_HR={cost}")

#!/usr/bin/env python3
"""App Store Connect release helper for VoType (runs in CI only).

Credentials come from env (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_CONTENT) and are
never printed. Output is limited to non-sensitive app state.

Actions:
  inspect     read-only report of app, versions, builds, groups, price, territories
  testflight  add the newest processed build to every internal beta group
  prepare     free price, all territories except mainland China, attach build
  submit      prepare + create and submit a review submission
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = os.environ.get("ASC_BUNDLE_ID", "com.daseanle.votype")
EXCLUDED_TERRITORIES = {"CHN"}


def token() -> str:
    key = os.environ["ASC_KEY_CONTENT"]
    if "BEGIN PRIVATE KEY" not in key:
        key = base64.b64decode(key).decode()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


_TOKEN = None


def call(method: str, path: str, body=None, ok=(200, 201, 204)):
    global _TOKEN
    _TOKEN = _TOKEN or token()
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {_TOKEN}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace")[:1500]
        raise RuntimeError(f"{method} {path.split('?')[0]} -> {err.code}: {detail}") from None


def get_all(path: str):
    items, url = [], path
    while url:
        page = call("GET", url)
        items.extend(page.get("data", []))
        url = page.get("links", {}).get("next")
    return items


def find_app():
    apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        raise RuntimeError(f"No app record for {BUNDLE_ID}")
    return apps[0]


def latest_builds(app_id, limit=5):
    return call("GET", f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit={limit}")["data"]


def internal_groups(app_id):
    return [g for g in get_all(f"/v1/betaGroups?filter[app]={app_id}&limit=50") if g["attributes"].get("isInternalGroup")]


def editable_version(app_id):
    versions = call("GET", f"/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    editable = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
    for v in versions:
        if v["attributes"]["appStoreState"] in editable:
            return v
    return None


def inspect(app):
    a = app["attributes"]
    print(f"APP id={app['id']} name={a.get('name')} sku-set={bool(a.get('sku'))} primaryLocale={a.get('primaryLocale')}")
    for v in call("GET", f"/v1/apps/{app['id']}/appStoreVersions?limit=10")["data"]:
        va = v["attributes"]
        print(f"VERSION {va['versionString']} state={va['appStoreState']} platform={va['platform']}")
    for b in latest_builds(app["id"]):
        ba = b["attributes"]
        print(f"BUILD {ba['version']} state={ba['processingState']} expired={ba['expired']} encryptionSet={ba.get('usesNonExemptEncryption') is not None} uploaded={ba['uploadedDate']}")
    for g in get_all(f"/v1/betaGroups?filter[app]={app['id']}&limit=50"):
        ga = g["attributes"]
        print(f"GROUP {ga['name']} internal={ga.get('isInternalGroup')} allBuilds={ga.get('hasAccessToAllBuilds')}")
    try:
        testers = get_all(f"/v1/betaTesters?filter[apps]={app['id']}&limit=200")
        print(f"TESTERS count={len(testers)}")
    except RuntimeError as err:
        print(f"TESTERS unavailable: {err}")
    for path, label in (("appPriceSchedule", "PRICE"), ("appAvailabilityV2", "AVAILABILITY")):
        try:
            data = call("GET", f"/v1/apps/{app['id']}/{path}")
            print(f"{label} present={bool(data.get('data'))}")
        except RuntimeError as err:
            print(f"{label} missing: {str(err)[:200]}")
    infos = call("GET", f"/v1/apps/{app['id']}/appInfos")["data"]
    for info in infos:
        ia = info["attributes"]
        print(f"APPINFO state={ia.get('appStoreState') or ia.get('state')} ageRating={ia.get('appStoreAgeRating')}")
    v = editable_version(app["id"])
    if v:
        try:
            detail = call("GET", f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail")
            d = (detail.get("data") or {}).get("attributes", {})
            filled = {k: bool(d.get(k)) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")}
            print(f"REVIEW_DETAIL filled={filled} demoRequired={d.get('demoAccountRequired')}")
        except RuntimeError as err:
            print(f"REVIEW_DETAIL missing: {str(err)[:200]}")
        build = call("GET", f"/v1/appStoreVersions/{v['id']}/build").get("data")
        print(f"VERSION_BUILD attached={bool(build)}")


def newest_valid_build(app_id, wait_minutes=40):
    deadline = time.time() + wait_minutes * 60
    while True:
        builds = latest_builds(app_id, 1)
        if builds and builds[0]["attributes"]["processingState"] == "VALID":
            return builds[0]
        state = builds[0]["attributes"]["processingState"] if builds else "none"
        if time.time() > deadline:
            raise RuntimeError(f"Newest build not processed in time (state={state})")
        print(f"waiting for processing, state={state}")
        time.sleep(60)


def testflight(app):
    build = newest_valid_build(app["id"])
    number = build["attributes"]["version"]
    if build["attributes"].get("usesNonExemptEncryption") is None:
        call("PATCH", f"/v1/builds/{build['id']}", {"data": {"type": "builds", "id": build["id"], "attributes": {"usesNonExemptEncryption": False}}})
        print(f"BUILD {number} export compliance set (no non-exempt encryption)")
    groups = internal_groups(app["id"])
    if not groups:
        raise RuntimeError("No internal beta group exists")
    pending = [g for g in groups if not g["attributes"].get("hasAccessToAllBuilds")]
    if pending:
        call("POST", f"/v1/builds/{build['id']}/relationships/betaGroups", {"data": [{"type": "betaGroups", "id": g["id"]} for g in pending]})
    print(f"TESTFLIGHT build {number} available to internal groups: {', '.join(g['attributes']['name'] for g in groups)}")
    return build


def set_free_price(app):
    points = get_all(f"/v1/apps/{app['id']}/appPricePoints?filter[territory]=USA&limit=200")
    free = next(p for p in points if float(p["attributes"]["customerPrice"]) == 0.0)
    body = {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": app["id"]}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]},
            },
        },
        "included": [{
            "type": "appPrices", "id": "${free}",
            "attributes": {"startDate": None},
            "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}},
        }],
    }
    call("POST", "/v1/appPriceSchedules", body)
    print("PRICE set to free")


def set_territories(app):
    territories = [t["id"] for t in get_all("/v1/territories?limit=200")]
    current = None
    try:
        current = call("GET", f"/v1/apps/{app['id']}/appAvailabilityV2").get("data")
    except RuntimeError:
        current = None
    if current:
        avail = get_all(f"/v2/appAvailabilities/{current['id']}/territoryAvailabilities?limit=200&include=territory")
        changed = 0
        for ta in avail:
            terr = ta["relationships"]["territory"]["data"]["id"]
            want = terr not in EXCLUDED_TERRITORIES
            if ta["attributes"].get("available") != want:
                call("PATCH", f"/v1/territoryAvailabilities/{ta['id']}", {"data": {"type": "territoryAvailabilities", "id": ta["id"], "attributes": {"available": want}}})
                changed += 1
        print(f"AVAILABILITY updated {changed} territories; excluded {sorted(EXCLUDED_TERRITORIES)}")
        return
    included, refs = [], []
    for i, terr in enumerate(territories):
        ref = f"${{ta{i}}}"
        refs.append({"type": "territoryAvailabilities", "id": ref})
        included.append({
            "type": "territoryAvailabilities", "id": ref,
            "attributes": {"available": terr not in EXCLUDED_TERRITORIES},
            "relationships": {"territory": {"data": {"type": "territories", "id": terr}}},
        })
    call("POST", "/v2/appAvailabilities", {
        "data": {
            "type": "appAvailabilities",
            "attributes": {"availableInNewTerritories": False},
            "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}, "territoryAvailabilities": {"data": refs}},
        },
        "included": included,
    })
    print(f"AVAILABILITY created for {len(territories) - len(EXCLUDED_TERRITORIES)} territories; excluded {sorted(EXCLUDED_TERRITORIES)}")


REVIEW_NOTES = (
    "VoType has no account or login. To test: 1) Open VoType. 2) Settings > General > Keyboard > "
    "Keyboards > Add New Keyboard > 声入, then enable Allow Full Access (needed only to exchange the "
    "current dictation session with the containing app through the App Group on device). 3) Grant "
    "Microphone and Speech Recognition in VoType. 4) In Notes, switch to the 声入 keyboard and tap the "
    "microphone; speak, tap again to stop, and the text is inserted. Optional: enable In-place Voice in "
    "VoType to show a Picture-in-Picture standby window that keeps the microphone off until the user "
    "taps the keyboard microphone. Speech is recognized by Apple's Speech framework; we run no servers."
)


def update_review_detail(version):
    detail = call("GET", f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    if not detail:
        raise RuntimeError("Review contact details are missing")
    call("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {
        "type": "appStoreReviewDetails", "id": detail["id"],
        "attributes": {"demoAccountRequired": False, "notes": REVIEW_NOTES},
    }})
    print("REVIEW_DETAIL demo account not required; reviewer notes set")


def prepare(app):
    build = testflight(app)
    version = editable_version(app["id"])
    if not version:
        raise RuntimeError("No editable App Store version; create 1.0 first (deliver does this)")
    call("PATCH", f"/v1/appStoreVersions/{version['id']}/relationships/build", {"data": {"type": "builds", "id": build["id"]}})
    print(f"VERSION {version['attributes']['versionString']} uses build {build['attributes']['version']}")
    update_review_detail(version)
    set_free_price(app)
    set_territories(app)
    return version


def submit(app):
    version = prepare(app)
    sub = call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}}}})["data"]
    call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
    }}})
    call("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {"type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}})
    print(f"SUBMITTED version {version['attributes']['versionString']} for review")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "inspect"
    app = find_app()
    {"inspect": inspect, "testflight": testflight, "prepare": prepare, "submit": submit}[action](app)
    if action != "inspect":
        inspect(app)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # report without leaking credentials
        print(f"ERROR: {exc}")
        sys.exit(1)

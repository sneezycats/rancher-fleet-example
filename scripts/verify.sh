#!/bin/bash
# EXAMPLE skeleton: run with CLUSTER_KUBECONFIG=<kubeconfig> ./verify.sh
# Verify trackable data survived the round: baseline identity intact,
# created-at unchanged, counters still growing, volumes attached+healthy.
set -uo pipefail
KC=${CLUSTER_KUBECONFIG:-/tmp/<cluster>-kubeconfig.yaml}
[ -f "$KC" ] || { echo "FATAL: kubeconfig not found: $KC — set CLUSTER_KUBECONFIG=<path-to-cluster-kubeconfig>"; exit 2; }
D=$(cd "$(dirname "$0")" && pwd)
[ -f "$D/baseline.json" ] || { echo "FATAL: no baseline.json — run baseline.sh first"; exit 2; }
python3 - "$KC" "$D/baseline.json" <<'PY'
import json, subprocess, sys
kc, base = sys.argv[1], sys.argv[2]
b=json.load(open(base))
def kb(*a):
    return subprocess.run(["kubectl","--kubeconfig",kc,*a], capture_output=True, text=True).stdout.strip()
def jp(*a):
    return json.loads(kb("get",*a,"-o","json"))
def replicas_for(vol):
    out=[]
    for r in jp("replicas.longhorn.io","-n","longhorn-system").get("items",[]):
        if r["metadata"]["name"].startswith(vol+"-r-"):
            out.append(r["spec"]["nodeID"])
    return sorted(out)
fails=[]
for pvc in b["volumes"]:
    v=b["volumes"][pvc]
    try:
        p=jp("pvc",pvc,"-n","default")
    except Exception as e:
        fails.append("{}: PVC gone ({})".format(pvc,e)); continue
    vol=p["spec"]["volumeName"]
    vv=jp("volumes.longhorn.io",vol,"-n","longhorn-system")
    st=vv.get("status",{})
    cond={c["type"]:c["status"] for c in st.get("conditions",[])}
    reps=replicas_for(vol)
    if p["metadata"]["uid"]!=v["pvc_uid"]: fails.append("{}: PVC UID changed".format(pvc))
    if vol!=v["volume"]: fails.append("{}: volume identity changed".format(pvc))
    if len(reps) < v["replicaCount"]: fails.append("{}: replica count dropped ({} -> {})".format(pvc,v["replicaCount"],len(reps)))
    if st.get("state")!="attached": fails.append("{}: state={} (want attached)".format(pvc,st.get("state")))
    if len(reps)==v["replicaCount"] and reps!=v["replicas"]:
        print("  note: replica NODES changed {} -> {} (expected across a hop)".format(v["replicas"],reps))
    if v.get("robustness") and st.get("robustness")!=v["robustness"]: fails.append("{}: robustness {} -> {}".format(pvc,v["robustness"],st.get("robustness")))
    if st.get("robustness")!="healthy": fails.append("{}: robustness={} (want healthy)".format(pvc,st.get("robustness")))
    if cond.get("Scheduled")!="True": fails.append("{}: not scheduled".format(pvc))
    suffix={"5g":"4bd9k","10g":"kwwlx","20g":"ngzmb"}[pvc.split("-")[2]]
    pod=[l.split()[0] for l in kb("get","pods","-n","default","--no-headers").splitlines() if ("lh-data-"+suffix) in l.split()[0]]
    if not pod:
        fails.append("{}: no writer pod".format(pvc)); continue
    ca=kb("exec","-n","default",pod[0],"--","cat","/data/created-at")
    wc=int(kb("exec","-n","default",pod[0],"--","sh","-c","wc -l < /data/counter").split()[0])
    cont=kb("exec","-n","default",pod[0],"--","cat","/data/start-log").strip()
    if ca!=v["created_at"]: fails.append("{}: created-at changed '{}' -> '{}'".format(pvc,v["created_at"],ca))
    if wc<=v["counter_lines"]: fails.append("{}: counter not growing ({} -> {})".format(pvc,v["counter_lines"],wc))
    print("{}: OK vol={} state={} robustness={} replicas={} created_at={} counter={}->{} cont={}".format(
        pvc,vol,st.get("state"),st.get("robustness"),reps,v["created_at"] or "n/a",v["counter_lines"],wc,
        (cont.splitlines()[-1] if cont else "n/a")))
if fails:
    print("VERIFY FAILED:")
    for f in fails: print(" -",f)
    sys.exit(1)
print("ALL VOLUMES OK — data trackable and continuous")
PY
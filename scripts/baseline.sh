#!/bin/bash
# Capture the test-data baseline: PVC identity, volume identity, created-at,
# counter lines, replica placement. Output: baseline.json (overwrites).
set -euo pipefail
KC=${CLUSTER_KUBECONFIG:-/tmp/<cluster>-kubeconfig.yaml}
[ -f "$KC" ] || { echo "FATAL: kubeconfig not found: $KC — set CLUSTER_KUBECONFIG=<path-to-cluster-kubeconfig>"; exit 2; }
D=$(cd "$(dirname "$0")" && pwd)
OUT=$D/baseline.json
echo "capturing baseline: $(date -u +%FT%TZ)"
python3 - "$KC" "$OUT" <<'PY'
import json, subprocess, sys, datetime
kc, out = sys.argv[1], sys.argv[2]
def kb(*a):
    return subprocess.run(["kubectl","--kubeconfig",kc,*a], capture_output=True, text=True, check=True).stdout.strip()
def jp(*a):
    return json.loads(kb("get",*a,"-o","json"))
def replicas_for(vol):
    out=[]
    for r in jp("replicas.longhorn.io","-n","longhorn-system").get("items",[]):
        if r["metadata"]["name"].startswith(vol+"-r-"):
            out.append(r["spec"]["nodeID"])
    return sorted(out)
bl={"captured_at_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),"volumes":{}}
for pvc in ["lh-test-5g","lh-test-10g","lh-test-20g"]:
    p=jp("pvc",pvc,"-n","default")
    vol=p["spec"]["volumeName"]
    v=jp("volumes.longhorn.io",vol,"-n","longhorn-system")
    st=v.get("status",{})
    cond={c["type"]:c["status"] for c in st.get("conditions",[])}
    bl["volumes"][pvc]={
        "pvc_uid":p["metadata"]["uid"],"volume":vol,
        "state":st.get("state"),"robustness":st.get("robustness"),
        "scheduled":cond.get("Scheduled"),
        "replicas":replicas_for(vol),"replicaCount":0,
        "created_at":None,"counter_lines":0}
    pods=kb("get","pods","-n","default","--no-headers").splitlines()
    suffix={"5g":"4bd9k","10g":"kwwlx","20g":"ngzmb"}[pvc.split("-")[2]]
    pod=[l.split()[0] for l in pods if ("lh-data-"+suffix) in l.split()[0]]
    if pod:
        bl["volumes"][pvc]["created_at"]=kb("exec","-n","default",pod[0],"--","cat","/data/created-at")
        bl["volumes"][pvc]["counter_lines"]=int(kb("exec","-n","default",pod[0],"--","sh","-c","wc -l < /data/counter").split()[0])
    bl["volumes"][pvc]["replicaCount"]=len(bl["volumes"][pvc]["replicas"])
open(out,"w").write(json.dumps(bl,indent=2)+"\n")
print(json.dumps(bl,indent=2))
PY
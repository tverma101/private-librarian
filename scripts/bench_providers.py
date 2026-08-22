#!/usr/bin/env python3
"""Lane-local provider benchmark — Issue #11. Offline, no network."""
from __future__ import annotations
import argparse, json, os, subprocess, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
def run(cmd, env=None, timeout=60):
    e=dict(os.environ)
    if env: e.update(env)
    t0=time.perf_counter()
    p=subprocess.run(cmd, cwd=str(ROOT), env=e, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr, time.perf_counter()-t0
def model_size_mb(p: Path) -> float:
    if not p.exists(): return 0.0
    total=p.stat().st_size if p.is_file() else sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    return round(total/(1024*1024),1)
def measure(kind: str, samples: int=5) -> dict:
    out={"kind":kind,"provisioned":False,"warmup_s":None,"p50_ms":None,"throughput_per_s":None,"model_mb":0,"notes":""}
    md=ROOT/"Models"
    if kind in ("coreml","mobileclip","mclip"):
        if (md/"mobileclip-s0"/"config.json").exists() or (md/"mobileclip-s0-coreml").exists():
            out["provisioned"]=True
            out["model_mb"]=model_size_mb(md/"mobileclip-s0-coreml") or model_size_mb(md/"mobileclip-s0")
        out["notes"]="Core ML experiment path — stubbed until .mlpackage bundled; falls back to Python. No crash when unavailable."
        kind="local"
        out["fallback_kind"]="local-model-bridge"
    if kind=="local":
        clip,mini=md/"clip-vit-base-patch32", md/"all-MiniLM-L6-v2"
        out["model_mb"]=round(model_size_mb(clip)+model_size_mb(mini),1)
        out["provisioned"]=(clip/"config.json").exists() or (mini/"config.json").exists()
        if not out["provisioned"]:
            out["notes"]="Models not provisioned — run provision_image_models.py --all (offline, explicit opt-in)"
            return out
        env={"HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1","LIBRARIAN_MODELS_DIR":str(md)}
        _,_,_,dt=run([sys.executable, str(ROOT/"scripts"/"embed.py"), "--check"], env=env, timeout=15)
        out["warmup_s"]=round(dt,3)
        lat=[]
        for _ in range(samples):
            t0=time.perf_counter()
            run([sys.executable, str(ROOT/"scripts"/"embed.py"), "--text", "benchmark synthetic document", "--model", "all-MiniLM-L6-v2"], env=env, timeout=15)
            lat.append((time.perf_counter()-t0)*1000)
            if len(lat)>=5: break
        lat.sort()
        out["p50_ms"]=round(lat[len(lat)//2],1)
        out["p95_ms"]=round(lat[int(len(lat)*0.95)] if len(lat)>1 else lat[0],1)
        if out["p50_ms"] and out["p50_ms"]>0: out["throughput_per_s"]=round(1000.0/out["p50_ms"],1)
    return out
def main():
    ap=argparse.ArgumentParser(description="Benchmark native vs Python providers (Issue #11)")
    ap.add_argument("--samples",type=int,default=5)
    ap.add_argument("--output",type=Path,default=Path("bench-providers.json"))
    ap.add_argument("--providers",nargs="*",default=["local","coreml"])
    args=ap.parse_args()
    results=[]
    for k in args.providers:
        print(f"[{k}] measuring...")
        r=measure(k, samples=args.samples)
        print(f"  -> {r}")
        results.append(r)
    payload={"schema":1,"issue":11,"providers":results,"notes":"Provisioning explicit/opt-in; runtime offline; providerID includes preprocessing hash for invalidation.","space_version":"see Indexer.embeddingSpaceVersion"}
    args.output.write_text(json.dumps(payload,indent=2))
    print(f"\nWrote {args.output}")
    print(json.dumps(payload,indent=2))
    return 0
if __name__=="__main__": raise SystemExit(main())

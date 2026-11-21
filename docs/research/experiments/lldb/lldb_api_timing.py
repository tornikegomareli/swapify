import sys, time, os
sys.path.insert(0, os.environ["LLDB_PY"])
import lldb
pid=int(sys.argv[1]); w=sys.argv[2]
t0=time.time()
dbg=lldb.SBDebugger.Create(False); dbg.SetAsync(False)
ci=dbg.GetCommandInterpreter()
tgt=dbg.CreateTarget("")
err=lldb.SBError()
proc=tgt.AttachToProcessWithID(dbg.GetListener(), pid, err)
t1=time.time(); print("attach_s", round(t1-t0,3), err.Success())
def run(cmd):
    r=lldb.SBCommandReturnObject(); s=time.time(); ci.HandleCommand(cmd, r); e=time.time()
    print(f"{cmd[:60]!r}: {round(e-s,3)}s ok={r.Succeeded()} out={r.GetOutput().strip()[-80:]!r} err={r.GetError().strip()[-120:]!r}")
for v in ("3","4"):
    s=time.time(); tok=proc.LoadImage(lldb.SBFileSpec(f"{w}/patch{v}.dylib"), err); e=time.time()
    print(f"LoadImage patch{v}: {round(e-s,3)}s token={tok} ok={err.Success()} {err.GetCString()}")
    dbg.SetAsync(True); proc.Continue(); time.sleep(0.8)
    dbg.SetAsync(False); s2=time.time(); proc.Stop(); print("stop_s", round(time.time()-s2,3), proc.GetState())
run('expr -l c -- (int)getpid()')
run('expr -l c -- (int)getpid()')
run('expr -l swift -- 1 + 2')
run('expr -l swift -- 1 + 2')
run('expr -l objc -- (int)[[NSProcessInfo processInfo] processIdentifier]')
s=time.time(); proc.Detach(); print("detach_s", round(time.time()-s,3))

import sys, time, os
sys.path.insert(0, os.environ["LLDB_PY"])
import lldb
pid=int(sys.argv[1]); w=sys.argv[2]
dbg=lldb.SBDebugger.Create(False); dbg.SetAsync(False)
t=dbg.CreateTarget(""); err=lldb.SBError()
s=time.time(); p=t.AttachToProcessWithID(dbg.GetListener(), pid, err); print("attach_s", round(time.time()-s,3))
for v in ("3","4"):
    s=time.time(); tok=p.LoadImage(lldb.SBFileSpec(f"{w}/patch{v}.dylib"), err); print(f"load patch{v}", round(time.time()-s,3), tok, err.Success())
ci=dbg.GetCommandInterpreter()
for c in ("expr -l swift -- 1 + 2","expr -l swift -- 1 + 2","expr -l c -- (int)getpid()"):
    r=lldb.SBCommandReturnObject(); s=time.time(); ci.HandleCommand(c,r); print(repr(c), round(time.time()-s,3), r.Succeeded(), r.GetOutput().strip())
s=time.time(); p.Detach(); print("detach_s", round(time.time()-s,3))

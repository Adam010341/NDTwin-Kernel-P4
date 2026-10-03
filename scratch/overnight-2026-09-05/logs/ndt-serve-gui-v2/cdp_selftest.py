# driver self-test against the v1 page on a stub server [Co-developed with claude code -- Adam]
import os, sys, tempfile
WT = "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927"
sys.path.insert(0, WT + "/tests/python"); sys.path.insert(0, WT + "/tests/browser")
import test_ndt_serve_gui as gui, cdp_pipe
s = gui.GuiServe().start()
s.behave(status={"stdout": "lab\n  claim          yours -- 30m left (until 23:59:00)\n  measuring      nothing\n"})
prof = tempfile.mkdtemp(prefix="chrome-profile-", dir=s.tmp)
env = dict(os.environ, HOME=s.home)
c = cdp_pipe.Chrome(prof, env=env)
try:
    p = c.page()
    p.navigate(open(os.path.join(s.conf(), "url")).read().strip())
    print("session:", p.wait_for("document.body.dataset.loaded"), p.eval("document.body.dataset.session"), p.eval("location.href"))
    print("visible:", p.eval("document.visibilityState"))
    q = c.page()
    print("after a 2nd page:", p.eval("document.visibilityState"))
    p.activate()
    print("after activate:", p.eval("document.visibilityState"))
    p.click("do-claim")
    p.wait_for("document.getElementById('confirm').open", 20)
    print("dialog open; typed row hidden:", p.eval("document.getElementById('c-typed-row').hidden"))
    p.wait_for("!document.getElementById('c-go').disabled", 20)
    print("dialog open, focus:", p.eval("document.activeElement.id"))
    p.focus("c-go"); p.key("Enter")
    import time; time.sleep(1)
    print("after Enter on Confirm, still open:", p.eval("document.getElementById('confirm').open"))
    p.click("c-go")
    p.wait_for("document.getElementById('actions-answer').textContent.length > 0", 20)
    print("after click:", p.eval("document.getElementById('actions-answer').textContent"))
finally:
    left = c.close()
    print("leftovers:", left)
    s.close()

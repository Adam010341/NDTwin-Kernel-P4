# pending_hup.py <cmd...> : block SIGHUP, raise SIGHUP in this process so it stays pending, then exec <cmd>.
# A pending signal and the mask survive execve, so <cmd> starts with a stop already pending. [Co-developed with claude code -- Adam]
import os, signal, sys
signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGHUP])
os.kill(os.getpid(), signal.SIGHUP)
os.execv(sys.argv[1], sys.argv[1:])

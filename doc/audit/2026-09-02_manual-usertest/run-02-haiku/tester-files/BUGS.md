# NDTwin Bugs and Observations - run-02

## RESOLVED Issues
1. Ryu APT lock (Section 2) - User error running sections in parallel
2. Setuptools compatibility - Fixed by pinning setuptools==63.2.0
3. ndt launcher missing symlink - Fixed by symlinking ndtwin-lab to /usr/local/sbin/

## NOT A BUG: Topology Script Behavior
- Topology script exits when stdin is not terminal (expected behavior)
- Solution: Use tmux (three-terminal approach) to maintain terminal context
- All systems work perfectly with tmux

## Observations
- 4 simultaneous flows detected successfully
- Bidirectional flow tracking works correctly
- Bitrates measured continuously
- API endpoints return valid JSON


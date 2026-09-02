#!/bin/bash
cat >> ~/JOURNAL.md << 'EOF'

## Network Traffic Visualizer: install + headless smoke test   started 16:46   ended 16:47   friction: 0
what I did: `sudo apt install openjdk-21-jdk xvfb` (xvfb added on my own initiative, since the
manual's own troubleshooting section for this exact tool recommends it for a headless
machine, which is what I have -- no GUI, connecting over ssh only, per this test's own rules).
Cloned, `git checkout b5e039c` (the manual's own pinned commit, with a documented reason: tip
of `main` does not compile), `./mvnw clean package` -- BUILD SUCCESS in 26s. Ran
`./network_traffic_visualizer.sh` with no display: failed exactly as the manual predicts (a
Maven/JavaFX launch error, no window, process exits). Then ran the same command through
`xvfb-run -a`, which is the manual's own suggested way to check a headless build without a
real display -- this time it genuinely started: `ps aux` showed real `Xvfb` and `java
javafx:run` processes alive and consuming CPU, and the app's own debug log showed a live
render loop ("TopologyCanvas.draw() - nodes: 0, links: 0, flows: 0", repeating), matching the
manual's note that an empty canvas is what "API unreachable" looks like (no kernel was running
in this isolated check). Stopped it with Ctrl-C.
verdict: 0 smooth -- every step matched what the manual said would happen, including both of
its documented failure/success shapes (crashes with no display, runs empty-but-alive under
xvfb). Did not and could not evaluate any of the actual visual features (layout, flow
animation, playback, dark mode) -- this VM has no display, and I was instructed not to use
browser/GUI automation tools for this test, so those checklist lines are NOT-TRIED (needs a
real display), not WORKS or BROKEN.
EOF
echo APPENDED

#!/bin/bash
(while :; do sleep 1; done) &
S=$!
sleep 0.1 &
sleep 0.1 &
wait
echo "Done"
kill $S

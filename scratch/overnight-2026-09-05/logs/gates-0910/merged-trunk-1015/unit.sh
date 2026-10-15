#!/usr/bin/env bash
# unit.sh <module>... : the named p4_proxy test modules, verbose, from p4_proxy/ of the clone it is run in.
# [Co-developed with claude code -- Adam]
cd p4_proxy && PYTHONPATH="$PWD" exec venv/bin/python -m unittest -v "$@"

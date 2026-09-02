#!/bin/bash
date +%H:%M
cd ~
echo "############ I01: clone both as siblings ############"
git clone https://github.com/ndtwin-lab/Simulation-Platform-Manager.git 2>&1 | tail -2
git clone https://github.com/ndtwin-lab/Energy-Saving-App.git 2>&1 | tail -2
ls -d ~/Simulation-Platform-Manager ~/Energy-Saving-App
echo "############ I05: the .example settings headers the manual names ############"
ls -l ~/Energy-Saving-App/include/app/settings.hpp.example 2>&1
ls -l ~/Simulation-Platform-Manager/include/settings/sim_server.hpp.example 2>&1
ls -l ~/Simulation-Platform-Manager/include/settings/app.hpp 2>&1
echo "############ I07: manual claim -- bare `make` builds no binary and exits 0 ############"
cd ~/Energy-Saving-App
make 2>&1 | tail -6
echo "BARE_MAKE_EXIT=$?"
echo "--- did a binary appear? ---"
ls -l energy_saving_simulator 2>&1
ls -l ../Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable 2>&1
echo "--- was a settings header generated? ---"
ls -l include/app/settings.hpp 2>&1
echo "############ I06: now the manual`s `make all` ############"
make all 2>&1 | tail -12
echo "MAKE_ALL_EXIT=$?"
ls -l energy_saving_simulator 2>&1
ls -l ../Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable 2>&1
date +%H:%M

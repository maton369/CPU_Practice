#!bin/bash

gcc CPU_emulator.c
./a.out | tee log.log

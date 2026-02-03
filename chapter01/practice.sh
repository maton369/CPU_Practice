#bin/bash

gcc sum.c
chmod +x a.out
./a.out | tee log.log

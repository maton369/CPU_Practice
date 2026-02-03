#bin/bash

gcc asm_sum.c
chmod +x a.out
./a.out | tee log.log

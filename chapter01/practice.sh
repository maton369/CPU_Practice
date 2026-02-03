#bin/bash

gcc asm_sum2.c
chmod +x a.out
./a.out | tee log.log

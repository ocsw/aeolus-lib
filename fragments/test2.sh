#!/bin/bash

i=0
while true; do
(( i++ ))
echo "test2 line $i" >> foo
s=`expr $RANDOM % 4`
sleep $s
done

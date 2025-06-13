#!/bin/bash
CHARS='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
LEN=$(( RANDOM % 17 + 16 ))
PASS=""
for ((i=0; i<LEN; i++)); do
  PASS+=${CHARS:RANDOM%${#CHARS}:1}
done
echo "$PASS"

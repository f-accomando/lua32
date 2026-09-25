#!/bin/sh
# run.sh - avvia s32 sul target reale (Raspberry Pi + HDMI via KMSDRM).
# Wrapper minimo: evita di dover ricordare/esportare SDL_VIDEODRIVER a
# mano ogni volta. Su un'altra macchina (es. desktop Linux con X11)
# basta lanciare "luajit main.lua" direttamente, senza questo script.
exec env SDL_VIDEODRIVER=kmsdrm luajit main.lua "$@"

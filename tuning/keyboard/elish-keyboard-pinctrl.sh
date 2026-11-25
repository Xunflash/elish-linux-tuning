#!/bin/bash
# Ensure LPASS LPI pinctrl (33c0000.pinctrl) is bound; early initramfs probe
# can time out on q6afe core clock before ADSP is ready, leaving the Xiaomi
# magnetic keyboard USB2 PHY (88e4000.phy -> a800000.usb) permanently deferred.
set -u

log() { logger -t elish-keyboard-pinctrl "$*"; }

DEV=/sys/bus/platform/devices/33c0000.pinctrl
DRV=/sys/bus/platform/drivers/qcom-sm8250-lpass-lpi-pinctrl

if [[ -d "$DEV" && ! -e "$DEV/driver" ]]; then
    log "rebinding 33c0000.pinctrl for magnetic keyboard USB PHY"
    modprobe pinctrl_sm8250_lpass_lpi 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        [[ -e "$DEV/driver" ]] && break
        if [[ -w "$DRV/bind" ]]; then
            printf '%s\n' 33c0000.pinctrl > "$DRV/bind" 2>/dev/null || true
        fi
        [[ -e "$DEV/driver" ]] && break
        sleep 1
    done
    if [[ -e "$DEV/driver" ]]; then
        log "33c0000.pinctrl bound successfully"
    else
        log "33c0000.pinctrl bind failed"
    fi
fi

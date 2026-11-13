# SPDX-License-Identifier: GPL-2.0-only
# summary: the boot-entry exception (kernel args + early initrd): show | set [--arg A]... [--initrd P [--last]] | clear | apply | restore [--slot A|B]
#
#   show     print the desired state and whether the slot's entry matches
#   set      record the desired kernel args / early initrd (--last puts the
#            initrd after the stock initramfs, which is what the modules
#            component's override needs) and apply them to the booted slot;
#            the update component re-applies on every update
#   clear    forget the desired state and restore the booted slot's entry
#   apply    reconcile the slot's entry with the desired state
#   restore  put the saved original back (hash-verified), or regenerate it
# Originals are saved under /var/lib/steamos-fixes/backup/<slot>/.

# shellcheck source=lib/slots.sh
. "$SOF_SRC/lib/slots.sh"

cmd_boot_entry() {
    local action=${1:-show} slot="" args="" initrd="" pos=first rel
    [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --slot)
                slot=$2
                shift
                ;;
            --arg)
                args="${args:+$args }$2"
                shift
                ;;
            --initrd)
                initrd=$2
                shift
                ;;
            --last) pos=last ;;
            *) die 2 "boot-entry: unknown argument '$1'" ;;
        esac
        shift
    done
    case "$action" in
        -h | --help | help)
            sed -n '3,11s/^# \{0,1\}//p' "$SOF_SRC/cmd/boot-entry.sh"
            return 0
            ;;
    esac
    if [ -z "$slot" ]; then
        slot=$(slots_active) || die "cannot determine the booted slot; pass --slot A|B"
    fi
    slots_valid_name "$slot" || die 2 "boot-entry: --slot must be A or B"
    case "$action" in
        show)
            rel=$(slots_entry_path "$slot" || true)
            printf 'slot:    %s\nentry:   %s\n' "$slot" "${rel:-none}"
            printf 'args:    %s\ninitrd:  %s%s\n' "$(slots_desired_get args || true)" "$(slots_desired_get initrd || true)" \
                "$([ "$(slots_desired_get initrd_pos 2>/dev/null)" = last ] && printf ' (last)')"
            if slots_entry_in_sync "$slot"; then printf 'state:   in sync\n'; else printf 'state:   needs apply\n'; fi
            ;;
        set)
            require_root "$action"
            [ -n "$initrd" ] && { slots_initrd_validate "$initrd" || die "refusing to record an invalid initrd"; }
            slots_desired_set "$args" "$initrd" "$pos"
            slots_entry_reconcile "$slot"
            ;;
        clear)
            require_root "$action"
            slots_desired_clear
            slots_entry_restore "$slot"
            ;;
        apply)
            require_root "$action"
            slots_entry_reconcile "$slot"
            ;;
        restore)
            require_root "$action"
            slots_entry_restore "$slot"
            ;;
        *) die 2 "boot-entry: expected show | set | clear | apply | restore" ;;
    esac
}

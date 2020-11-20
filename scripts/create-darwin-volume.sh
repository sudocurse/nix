#!/usr/bin/env bash
set -eu

# support import-only `. create-darwin-volume.sh no-main[ ...]`
if [ "${1-}" = "no-main" ]; then
    shift
    readonly _CREATE_VOLUME_NO_MAIN=1
else
    readonly _CREATE_VOLUME_NO_MAIN=0
    # declare some things we expect to inherit from install-multi-user
    # I don't love this (because it's a bit of a kludge)
    readonly NIX_ROOT="${NIX_ROOT:-/nix}"
    readonly ESC='\033[0m'
    readonly GREEN='\033[32m'
    readonly RED='\033[31m'
    _sudo() {
        shift # throw away the 'explanation'
        /usr/bin/sudo "$@"
    }
    failure() {
        if [ "$*" = "" ]; then
            cat
        else
            echo "$@"
        fi
        exit 1
    }
    task() {
        echo "$@"
    }
fi

# make it easy to play w/ 'Case-sensitive APFS'
readonly NIX_VOLUME_FS="${NIX_VOLUME_FS:-APFS}"
readonly NIX_VOLUME_LABEL="${NIX_VOLUME_LABEL:-Nix}"
# shellcheck disable=SC1003,SC2026
readonly NIX_VOLUME_FOR_FSTAB="${NIX_VOLUME_LABEL/ /'\\\'040}" # pre-escaped
readonly NIX_VOLUME_MOUNTD_DEST="${NIX_VOLUME_MOUNTD_DEST:-/Library/LaunchDaemons/org.nixos.darwin-store.plist}"

# run something, cache stdout/status (by making a function)
# and return future calls from the cache. This has limits;
# (i.e., you have to cache each bit in a pipeline, not the
# whole thing, etc.), so don't try to be too cute with it.
cache() {
    printf -v cache_key_funcname "◊%s" "${@// /⦚}"
    # declare the cachefunc if it doesn't exist
    if ! declare -F $cache_key_funcname &>/dev/null; then
        IFS=◊ read -r -d "" out code < <("$@"; echo ◊$?)
        code=${code:-1}
        eval "
        $cache_key_funcname() {
            printf '%s' '$out'
            return $code
        }
        "
    fi
    # regardless, get output/status by running it
    $cache_key_funcname
}

# not used yet, but I'm sure invalidation will eventually be an issue...
uncache() {
    printf -v cache_key_funcname "◊%s" "${@// /⦚}"
    unset "$cache_key_funcname"
}

# usually "disk1"
root_disk_identifier() {
    # For performance (~10ms vs 280ms) I'm parsing 'diskX' from stat output
    # (~diskXsY)--but I'm retaining the more-semantic approach since
    # it documents intent better.
    # /usr/sbin/diskutil info -plist / | xmllint --xpath "/plist/dict/key[text()='ParentWholeDisk']/following-sibling::string[1]/text()" -
    #
    special_device="$(/usr/bin/stat -f "%Sd" /)"
    echo "${special_device/s[0-9]*/}"
}

# Strongly assuming we'll make a volume on the device root is on
# But you can override NIX_VOLUME_USE_DISK to create it on some other device
readonly NIX_VOLUME_USE_DISK="${NIX_VOLUME_USE_DISK:-$(root_disk_identifier)}"

substep() {
    printf "   %s\n" "" "- $1" "" "${@:2}"
}

printf -v _UNCHANGED_GRP_FMT "%b" $'\033[2m%='"$ESC" # "dim"
# bold+invert+red and bold+invert+green just for the +/- below
# red/green foreground for rest of the line
printf -v _OLD_LINE_FMT "%b" $'\033[1;7;31m-'"$ESC ${RED}%L${ESC}"
printf -v _NEW_LINE_FMT "%b" $'\033[1;7;32m+'"$ESC ${GREEN}%L${ESC}"
_diff() {
    /usr/bin/diff --unchanged-group-format="$_UNCHANGED_GRP_FMT" --old-line-format="$_OLD_LINE_FMT" --new-line-format="$_NEW_LINE_FMT" --unchanged-line-format="  %L" "$@"
}

confirm_rm() {
    if ui_confirm "Can I remove $1?"; then
        # ok "Yay! Thanks! Let's get going!"
        _sudo "to remove $1" rm "$1"
    fi
}
confirm_edit() {
    cat <<EOF

It looks like Nix isn't the only thing here, but I think I know how to edit it
out. Here's the diff:
EOF

    # could technically test the diff, but caller should do it
    _diff "$1" "$2"
    if ui_confirm "Does the change above look right?"; then
        # ok "Yay! Thanks! Let's get going!"
        _sudo "remove nix from $1" cp "$2" "$1"
    fi
}

volume_info() {
    /usr/sbin/diskutil info -plist "$1"
}

# TODO: validate string => * in all 3 of these
# $1 = volume label
volume_uuid() {
    cache volume_info "$1" | xmllint --xpath "(/plist/dict/key[text()='VolumeUUID']/following-sibling::*[1]/text())" - 2>/dev/null
}

# $1 = volume label
# TODO: unused
volume_special_device() {
    cache volume_info "$1" | volinfo_special_device
}

# $1 = volume label
volume_disk() {
    cache volume_info "$1" | xmllint --xpath "(/plist/dict/key[text()='ParentWholeDisk']/following-sibling::*[1]/text())" - 2>/dev/null
}

# DOING: I'm adding a new idiom here for getting diskinfo because I feel like we're frittering
# a lot of time away doing all of these little xml checks relative to just extracting the info
# once and caching or passing it.
#
# There's one asterisk here, which is that the diskutil command is still expensive, so it may
# still make sense to run a cheaper check like volume_exists, since we can skip enumerating
# the volumes if we already know none of them are present
# TODO: unused
volume_list() {
    diskutil apfs list -plist
}

# most diskutil commands are atrociously slow to be using to answer individual
# queries/questions (diskutil apfs list -plist regularly takes .75-1.25s on my
# 2020 MBA) so we'll run it once and fling it through xslt to answer
# all of the questions we have.
#
# Another sad factor here is that we can actually get *most* of this information
# from ioreg with a similar process--but the encrypted and encryptiontype keys
# there don't seem to indicate whether it's FV-encrypted (they're always true on T2)
#
# So here I'll keep a list of the ways I've identified to test volume encryption:
#
# diskutil apfs unlockVolume -verify with an intentionally-bad password:
# - ~100ms to fail on disk not encrypted
# - ~180ms to fail on bad password
# - plus time to disambiguate the above failures
#
# diskutil apfs decryptVolume with an intentionally-bad password:
# - ~60ms to fail on disk not encrypted
# - ~225ms to fail on bad password
# - plus time to disambiguate
#
# diskutil info -plist disk1s8 | xmllint --xpath
# - ballpark 250-300ms for both cases
# - directly fails
# - BUT: if you already have to pull diskutil info for this disk
#   it's only about ~7ms *more* to run this test
#
# diskutil apfs listCryptoUsers <special>
# - ~40ms for status 1 if there's no disk
# - ~60ms for status 0 if there are no crypto users
# - ~100ms for status 0 if there are crypto users (~90ms if plist)
# - I don't *know* this perfectly correlates, but it seems likely
#
# security find-generic-password -s <UUID>
# - ~50-80ms hit or miss
# - this doesn't strongly correlate, but we *will* have to pull it
#   if we find out that the disk is encrypted, so if we've already
#   got some strong context clues, it *might* make sense to just
#   try fetching the password, use unlock -verify, skate if we pass
#   and parse output to figure out if we're actually encrypted
#   if we fail?
#
# diskutil apfs list -plist | xsltproc
# - as noted before, this is very slow .75-1.25s, but it does score
#   us most of the information we need for all volumes (and the
#   xsltproc is fairly cheap with --novalid), so it seems at least
#   plausible that, once you pencil out all of the checks, it'll
#   be "better" in some clear way to just hard pull all of the volumes at once
# - yes filevault
# - no mountpoint
#
# ioreg -ra -n "Nix Store" | xsltproc
# - This is *very* quick for the information we get (~50ms) w/o
#   any caching, but it doesn't have everything we want (namely, mountpoint
#   and whether we have filevault)
#
# /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -k disk1s7
# - This is about 20ms on first run and 11 after; not bad, but we do already
#   need to know the device (and I'm not certain we will when this would be
#   most helpful?)
#
# /bin/df -nlP /nix
# - get the special device in ~5-15ms
# - plus parse time
#
# /usr/bin/stat -f "%Sd" /nix
# - special device in ~8-10ms, no parsing needed
# - this can, in theory, lie; if our new volume doesn't mount for some reason
#   it'll just report the root special device
#
# this extracts one lozenge(◊)-separated list per volume where the label is
# "Nix Store" or "$NIX_VOLUME_LABEL"
volinfo() {
    # --novalid cut runtime 80ms -> 8ms for me
    xsltproc --novalid --stringparam label "$NIX_VOLUME_LABEL" - <(cache volume_list) <<'EOF'
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
  <xsl:output method="text"/>
  <xsl:template match="/">
    <xsl:apply-templates select="//key[text()='Name']/following-sibling::*[1][text()=$label]/..">
      <xsl:sort select="position()" data-type="number" order="descending"/>
    </xsl:apply-templates>
  </xsl:template>
  <xsl:template match="dict">
    <xsl:apply-templates match="string" select="key[text()='DeviceIdentifier']/following-sibling::*[1]"/>
    <xsl:text>◊</xsl:text>
    <xsl:apply-templates match="string" select="key[text()='Name']/following-sibling::*[1]"/>
    <xsl:text>◊</xsl:text>
    <xsl:apply-templates match="string" select="key[text()='APFSVolumeUUID']/following-sibling::*[1]"/>
    <xsl:text>◊</xsl:text>
    <xsl:apply-templates match="true|false" select="key[text()='FileVault']/following-sibling::*[1]"/>
    <xsl:text>&#xA;</xsl:text>
  </xsl:template>
  <xsl:template match="true|false">
    <xsl:value-of select="number(name()='true')"/>
  </xsl:template>
</xsl:stylesheet>
EOF
}

# There are multiple *volume_exists functions here because there are some dumb
# perf/correctness tradeoffs...
#
# volume_exists (diskutil apfs listSnapshots) is the fastest way I've found to
#   check if a volume exists by label (~55-70ms on 2020 MBA), but it doesn't
#   tell you what disk it's on or disambiguate if there are multiple volumes.
#
# disk_volume_exists (diskutil apfs list <special> | long xpath query) answers
#   the question for a single disk, but an order of magnitude slower (~750ms)
#   It doesn't disambiguate if there are multiple volumes.

# $1 = label
volumes_labeled() {
    xsltproc --novalid --stringparam label "$1" - <(ioreg -ra -c "AppleAPFSVolume") <<'EOF'
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
  <xsl:output method="text"/>
  <xsl:template match="/">
    <xsl:apply-templates select="/plist/array/dict/key[text()='IORegistryEntryName']/following-sibling::*[1][text()=$label]/.."/>
  </xsl:template>
  <xsl:template match="dict">
    <xsl:apply-templates match="string" select="key[text()='BSD Name']/following-sibling::*[1]"/>
    <xsl:text>◊</xsl:text>
    <xsl:apply-templates match="string" select="key[text()='IORegistryEntryName']/following-sibling::*[1]"/>
    <xsl:text>◊</xsl:text>
    <xsl:apply-templates match="string" select="key[text()='UUID']/following-sibling::*[1]"/>
    <xsl:text>&#xA;</xsl:text>
  </xsl:template>
</xsl:stylesheet>
EOF
}

# $1 = label
cure_volumes() {
    # DOING: starting to think the way this actually works is that *this* is the outer loop, and that it invokes the correct inner functions with these values...
    local found="" special label uuid
    # loop just in case they have more than one volume
    # (nothing stops you from doing this)
    while IFS=◊ read -r special label uuid; do
        # take the first one that's on the right disk
        if [ -z "$found" ]; then
            if [ "${special::${#NIX_VOLUME_USE_DISK}}" = "$NIX_VOLUME_USE_DISK" ]; then
                cure_volume "$special" "$uuid"
                found="${special} (${uuid})"
            else
                warning "Ignoring ${special} (${uuid}) because it isn't on $NIX_VOLUME_USE_DISK"
                # TODO: if ! headless, chance to delete?
            fi
        else
            warning "Ignoring ${special} (${uuid}), already found target: $found"
            # TODO reminder? I feel like I want one
            # idiom that reminds some warnings, or warns
            # some reminders?
            # TODO: if ! headless, chance to delete?
        fi
    done < <(volumes_labeled "$1")

    test -n "$found" # return true if we found a volume?
}

# $1 = volume label
# This is searching *any* disk
volume_exists() {
    # TODO: diskutil may not need abspath; my worry is gnu stuff
    # cryptousers may be narrowly faster than snapshots, but they're both around 60ms
    /usr/sbin/diskutil apfs listCryptoUsers "$1" >/dev/null
    /usr/sbin/diskutil apfs listSnapshots "$1" >/dev/null
    # below looks to be more like 30ms
    # Note that it's a bit arcane;
    # - ioreg doesn't seem to fail, at least not under conditions we care about
    # - there's output if it's found, and no output if not
    # - the read builtin returns 1 when it hits EOF
    # so we try to read 1 character and assume a volume exists if true
    # notes: I just use -n in persistence.sh, and I am picking up -d from there; test both
    if read -r -N 1 -d '' hehe < <(ioreg -r -n "$NIX_VOLUME_LABEL"); then
        # volume exists
    fi
    if read -r -N 1 hehe < <(ioreg -r -n "$NIX_VOLUME_LABEL"); then
        # volume exists
    fi
    if read -r -n 1 -d '' hehe < <(ioreg -r -n "$NIX_VOLUME_LABEL"); then
        # volume exists
    fi
    if read -r -n 1 hehe < <(ioreg -r -n "$NIX_VOLUME_LABEL"); then
        # volume exists
    fi
}

# $1 = volume label
# This is searching *any* disk
# TODO: probably obsolete
# volume_encrypted() {
#     cache volume_info "$1" | volinfo_filevault
# }
volume_encrypted() {
    diskutil apfs listCryptoUsers "$1" | /usr/bin/grep -q "No cryptographic users for $1"
}
# TODO: unused
volinfo_filevault() {
    xmllint --xpath "(/plist/dict/key[text()='FileVault'])/following-sibling::*[1][name()='true']" &>/dev/null
}
# TODO: unused
volinfo_special_device() {
    xmllint --xpath "(/plist/dict/key[text()='DeviceIdentifier']/following-sibling::*[1]/text())" - 2>/dev/null
}

# this is searching *any* disk
# TODO: unused
nix_volume_exists() {
    cache volume_exists "$NIX_VOLUME_LABEL"
}

# TODO: unused
# $1 = disk special, $2 = volume label
disk_volume_exists() {
    /usr/sbin/diskutil apfs list -plist "$1" | xmllint --xpath "(/plist/dict/array/dict/key[text()='Volumes']/following-sibling::array/dict/key[text()='Name']/following-sibling::*[1][text()='$2'])[1]" - &>/dev/null
}
# TODO: unused
find_nix_volume() {
    disk_volume_exists "$NIX_VOLUME_USE_DISK" "$NIX_VOLUME_LABEL"
}

test_fstab() {
    /usr/bin/grep -q "$NIX_ROOT apfs rw" /etc/fstab 2>/dev/null
}

test_nix_symlink() {
    [ -L "$NIX_ROOT" ] || /usr/bin/grep -q "^nix." /etc/synthetic.conf 2>/dev/null
}
test_synthetic_conf_mountable() {
    /usr/bin/grep -q "^${NIX_ROOT:1}$" /etc/synthetic.conf 2>/dev/null
}
test_synthetic_conf_symlinked() {
    /usr/bin/grep -qE "^${NIX_ROOT:1}\s+\S{3,}" /etc/synthetic.conf 2>/dev/null
}

test_nix_volume_mountd_installed() {
    test -e "$NIX_VOLUME_MOUNTD_DEST"
}

# true here is a cruft smell when ! test_keychain_by_uuid
# TODO may be obsolete already
test_keychain_by_label() {
    # Note: doesn't need sudo just to check; doesn't output pw
    security find-generic-password -a "$NIX_VOLUME_LABEL" &>/dev/null
}
# current volume password
# $1 = uuid
test_keychain_by_uuid() {
    # Note: doesn't need sudo just to check; doesn't output pw
    security find-generic-password -s "$1" &>/dev/null
}

get_volume_pass() {
    sudo security find-generic-password -s "$(cache volume_uuid "$NIX_VOLUME_LABEL")" -w
    # TODO: maybe
    sudo security find-generic-password -s "$1" -w
}

# $1 = special device, $2 = uuid?
verify_volume_pass() {
    diskutil apfs unlockVolume "$1" -verify -stdinpassphrase -user "$2"
}

# $1 = special device, $2 = uuid?
# TODO: leaving it as-is for now, but I think we
# can get both from the special device or the uuid
volume_pass_works() {
    get_volume_pass "$1" | verify_volume_pass "$1" "$2"
}

# Create the paths defined in synthetic.conf, saving us a reboot.
create_synthetic_objects() {
    # Big Sur takes away the -B flag we were using and replaces it
    # with a -t flag that appears to do the same thing (but they
    # don't behave exactly the same way in terms of return values).
    # This feels a little dirty, but as far as I can tell the
    # simplest way to get the right one is to just throw away stderr
    # and call both... :]
    {
        /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t || true # Big Sur
        /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -B || true # Catalina
    } >/dev/null 2>&1
}

test_nix() {
    test -d "$NIX_ROOT"
}

test_voldaemon() {
    test -f "$NIX_VOLUME_MOUNTD_DEST"
}

if /usr/bin/fdesetup isactive >/dev/null; then
    test_filevault_in_use() { return 0; }
else
    test_filevault_in_use() { return 1; }
fi

# $1 == encrypted|unencrypted, $2 == uuid
generate_mount_command() {
    case "${1-}" in
        encrypted)
            printf "    <string>%s</string>\n" /bin/sh -c "/usr/bin/security find-generic-password -s '$2' -w | /usr/sbin/diskutil apfs unlockVolume '$2' -mountpoint $NIX_ROOT -stdinpassphrase";;
        unencrypted)
            printf "    <string>%s</string>\n" /usr/sbin/diskutil mount -mountPoint "$NIX_ROOT" "$2";;
        *)
            failure "Invalid first arg $1 to generate_mount_command";;
    esac
}

# $1 == encrypted|unencrypted, $2 == uuid
generate_mount_daemon() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>RunAtLoad</key>
  <true/>
  <key>Label</key>
  <string>org.nixos.darwin-store</string>
  <key>ProgramArguments</key>
  <array>
$(generate_mount_command "$1" "$2")
  </array>
</dict>
</plist>
EOF
}

# TODO: this is a succinct example of an annoyance I have: I'd like to
# dedup "direction" and "prompt" cases into a goal/command/explanation...
#
# uninstall_launch_daemon_abstract() {
#     goal "uninstall LaunchDaemon $1"
#     to "terminate the daemon" \
#         run sudo launchctl bootout "system/$1"
#     to "remove the daemon definition" \
#         run sudo rm "$2"
# }
#
# One way to make something like this work would be passing in ~closures
# uninstall_launch_daemon_abstract "substep" "print_action"
# uninstall_launch_daemon_abstract "ui_confirm" "run_action"
#
# But in some cases the approach a human and our script need to take diverge
# by enough to challenge this paradigm, as in
# synthetic_conf_uninstall_directions|prompt
uninstall_launch_daemon_directions() {
    substep "Uninstall LaunchDaemon $1" \
      "  sudo launchctl bootout system/$1" \
      "  sudo rm $2"
}

_eat_bootout_err() {
    grep -v "Boot-out failed: 36: Operation now in progress" 1>&2
}

uninstall_launch_daemon_prompt() {
    cat <<EOF

The installer added $1 (a LaunchDaemon
to $3).
EOF
    if ui_confirm "Can I remove it?"; then
        _sudo "to terminate the daemon" \
            launchctl bootout "system/$1" 2> >(_eat_bootout_err) || true
        # if ! _sudo "to terminate the daemon" \
        #     launchctl bootout "system/$1" 2> >(_eat_bootout_err); then
        #     # this can "fail" with a message like:
        #     # Boot-out failed: 36: Operation now in progress
        #     # I gather it still works, but let's test
        #     # launchctl blame will *fail* if it has been removed
        #     if ! _sudo "to confirm its removal" \
        #         launchctl blame "system/$1" 2>/dev/null; then
        #         failure "error: failed to unload LaunchDaemon system/$1"
        #     fi
        #     # if already removed, this returned 113 and emitted roughly:
        #     # Could not find service "$1" in domain for system
        # fi
        _sudo "to remove the daemon definition" rm "$2"
    fi
}
nix_volume_mountd_uninstall_directions() {
    uninstall_launch_daemon_directions "org.nixos.darwin-store" \
        "$NIX_VOLUME_MOUNTD_DEST"
}
nix_volume_mountd_uninstall_prompt() {
    uninstall_launch_daemon_prompt "org.nixos.darwin-store" \
        "$NIX_VOLUME_MOUNTD_DEST" \
        "mount your Nix volume"
}
nix_daemon_uninstall_directions() {
    uninstall_launch_daemon_directions "org.nixos.nix-daemon" \
        "$NIX_DAEMON_DEST"
}
nix_daemon_uninstall_prompt() {
    uninstall_launch_daemon_prompt "org.nixos.nix-daemon" \
        "$NIX_DAEMON_DEST" \
        "run the nix-daemon"
}

synthetic_conf_uninstall_directions() {
    # :1 to strip leading slash
    substep "Remove ${NIX_ROOT:1} from /etc/synthetic.conf" \
        "  If nix is the only entry: sudo rm /etc/synthetic.conf" \
        "  Otherwise: grep -v '^${NIX_ROOT:1}$' /etc/synthetic.conf | sudo dd of=/etc/synthetic.conf"
}

synthetic_conf_uninstall_prompt() {
    cat <<EOF
During install, I add '${NIX_ROOT:1}' to /etc/synthetic.conf, which
instructs macOS to create an empty root directory where I can mount
the Nix volume.
EOF
    # there are a few things we can do here
    # 1. if grep -v didn't match anything (also, if there's no diff), we know this is moot
    # 2. if grep -v was empty (but did match?) I think we know that we can just remove the file
    # 3. if the edit doesn't ~empty the file, show them the diff and ask
    if ! grep -v '^'"${NIX_ROOT:1}"'$' /etc/synthetic.conf > "$SCRATCH/synthetic.conf.edit"; then
        if confirm_rm "/etc/synthetic.conf"; then
            return 0
        fi
    else
        if cmp <<<"" "$SCRATCH/synthetic.conf.edit"; then
            # this edit would leave it empty; propose deleting it
            if confirm_rm "/etc/synthetic.conf"; then
                return 0
            fi
        else
            if confirm_edit "$SCRATCH/synthetic.conf.edit" "/etc/synthetic.conf"; then
                return 0
            fi
        fi
    fi
    # fallback instructions
    echo "Manually remove nix from /etc/synthetic.conf"
    return 1
}

add_nix_vol_fstab_line() {
    uuid="$1"
    shift
    EDITOR="/usr/bin/ex" _sudo "to add nix to fstab" "$@" <<EOF
:a
UUID=$uuid $NIX_ROOT apfs rw,noauto,nobrowse,suid,owners
.
:x
EOF
    # TODO: preserving my notes on suid,owners above until resolved
    # There *may* be some issue regarding volume ownership, see nix#3156
    #
    # It seems like the cheapest fix is adding "suid,owners" to fstab, but:
    # - We don't have much info on this condition yet
    # - I'm not certain if these cause other problems?
    # - There's a "chown" component some people claim to need to fix this
    #   that I don't understand at all yet
    #
    # I'm not sure if it's safe to approach this way?
    #
    # I think I think the most-proper way to test for it is:
    # diskutil info -plist "$NIX_VOLUME_LABEL" | xmllint --xpath "(/plist/dict/key[text()='GlobalPermissionsEnabled'])/following-sibling::*[1][name()='true']" -; echo $?
    #
    # There's also `sudo vsdbutil -c /path` (which is much faster, but is also
    # deprecated and needs minor parsing).
    #
    # If no one finds a problem with doing so, I think the simplest approach
    # is to just eagerly set this. I found a few imperative approaches:
    # (diskutil enableOwnership, ~100ms), a cheap one (vsdbutil -a, ~40-50ms),
    # a very cheap one (append the internal format to /var/db/volinfo.database).
    #
    # But vsdbutil's deprecation notice suggests using fstab, so I want to
    # give that a whirl first.
}

delete_nix_vol_fstab_line() {
    # TODO: I'm scaffolding this to handle the new nix volumes
    # but it might be nice to generalize a smidge further to
    # go ahead and set up a pattern for curing "old" things
    # we no longer do?
    EDITOR="/usr/bin/patch" _sudo "to cut nix from fstab" "$@" < <(diff /etc/fstab <(grep -v "$NIX_ROOT apfs rw" /etc/fstab))
    # leaving some parts out of the grep; people may fiddle this a little?
}

fstab_uninstall_directions() {
    substep "Remove ${NIX_ROOT} from /etc/fstab" \
      "  If nix is the only entry: sudo rm /etc/fstab" \
      "  Otherwise, run 'sudo vifs' to remove the nix line"
}

fstab_uninstall_prompt() {
    cat <<EOF
During install, I add '${NIX_ROOT}' to /etc/fstab so that macOS knows what
mount options to use for the Nix volume.
EOF
    cp /etc/fstab "$SCRATCH/fstab.edit"
    # technically doesn't need the _sudo path, but throwing away the
    # output is probably better than mostly-duplicating the code...
    delete_nix_vol_fstab_line patch "$SCRATCH/fstab.edit" &>/dev/null

    # if the patch test edit, minus comment lines, is equal to empty (:)
    if diff -q <(:) <(grep -v "^#" "$SCRATCH/fstab.edit") &>/dev/null; then
        # this edit would leave it empty; propose deleting it
        if confirm_rm "/etc/fstab"; then
            return 0
        else
            echo "Remove nix from /etc/fstab (or remove the file)"
        fi
    else
        echo "I might be able to help you make this edit. Here's the diff:"
        if ! _diff "/etc/fstab" "$SCRATCH/fstab.edit" && ui_confirm "Does the change above look right?"; then
            delete_nix_vol_fstab_line vifs
        else
            echo "Remove nix from /etc/fstab (or remove the file)"
        fi
    fi
}

# TODO: unused
volume_uninstall_directions() {
    # TODO: below needs UUID fed (if fn not cut)
    if test_keychain_by_uuid; then
        keychain_uuid_uninstall_directions
    fi
    substep "Destroy the nix data volume" \
      "  sudo diskutil apfs deleteVolume $(cache volume_special_device "$NIX_VOLUME_LABEL")"
}

# $1 = special device
remove_volume() {
    _sudo "to unmount the Nix volume" \
        diskutil unmount force "$1" || true # might not be mounted
    _sudo "to delete the Nix volume" \
        diskutil apfs deleteVolume "$1"
}

# aspiration: robust enough to both fix problems
# *and* update older darwin volumes
# $1 = special $2 = uuid
cure_volume() {
    # TODO: cut below once settled
    # math out runtime of paths through these conditionals
    # 1 diskutil (7-357ms) (if we've cached diskinfo - if not)
    #   test keychain ~60ms
    #   fetch keychain ~60ms
    #       try unlock ~100-180ms
    #   7-357 if not encrypted
    #   67-417 if encrypted but no cred
    #   227-657 if encrypted and cred
    #   maybe 160-597 if keychain steps combined
    # 2 listcrypto 60-100ms
    #   test keychain ~60ms
    #   fetch keychain ~60ms
    #       try unlock ~100-180ms
    #   60ms if not encrypted
    #   160ms if encrypted but no cred
    #   320-400 if encrypted and cred
    #   maybe 260-340 if keychain steps combine
    if volume_encrypted "$1"; then
        if volume_pass_works "$1" "$2"; then
            :
        else
            # - this is a volume we made, and
            #   - the user encrypted it on their own
            #   - something deleted the credential
            # - this is an old or BYO volume and the pw
            #   just isn't somewhere we can find it.
            #
            # We're going to explain why we're freaking out
            # and prompt them to either delete the volume
            # (requiring a sudo auth), or abort to fix
            warning <<EOF
This volume is encrypted, but I don't see a password to decrypt it.
The quick fix is to let me delete this volume and make you a new one.
If that's okay, enter your (sudo) password to continue. If not, you
can ensure the decryption password is in your system keychain with a
"Where" (service) field set to this volume's UUID ($2).
EOF
            if password_confirm "delete this volume"; then
                remove_volume
            else
                # TODO: this is a good design case for a warn-and
                # remind idiom...
                reminder <<EOF
Your Nix volume is encrypted, but I couldn't find its password. Either:
- Delete or rename the volume out of the way
- Ensure its decryption password is in the system keychain with a
  "Where" (service) field set to this volume's UUID ($2)
EOF
        fi
    elif test_filevault_in_use; then
        warning "FileVault on, but your $NIX_VOLUME_LABEL volume isn't encrypted."
        # if we're interactive, give them a chance to
        # encrypt the volume. If not, /shrug
        if ! headless; then
            # TODO: not actually sure if this headless check is here or in a UI/X idiom
            if ui_confirm "Should I encrypt it and add the decryption key to your keychain?"; then
                encrypt_volume "$2" "$NIX_VOLUME_LABEL"
            else
                reminder "FileVault on, but your $NIX_VOLUME_LABEL volume isn't encrypted."
            fi
        fi
    fi
    remove_volume_artifacts
}

remove_volume_artifacts() {
    if test_synthetic_conf_mountable; then
        if synthetic_conf_uninstall_prompt; then
            # TODO: moot until we tackle uninstall, but when we're
            # actually uninstalling, we should issue:
            # reminder "macOS will clean up the empty mount-point directory at $NIX_ROOT on reboot."
            :
        fi
    fi
    if test_fstab; then
        fstab_uninstall_prompt
    fi

    # TODO: disabling this for rethink... if we let them
    # keep volumes, we have to exhaustively rule out
    # potential volumes before checking this
    # Not certain. Target case is an orphaned credential...
    # TODO: below needs UUID fed
    # if ! test_keychain_by_uuid && test_keychain_by_label; then
    #     keychain_label_uninstall_prompt
    # fi
    if test_nix_volume_mountd_installed; then
        nix_volume_mountd_uninstall_prompt
    fi
}
# TODO: may be obsolete already :}
# only a function for keychain_label; the keychain_uuid
# case is handled in volume_uninstall_prompt.
keychain_label_uninstall_prompt() {
    cat <<EOF

It looks like your keychain has at least 1 orphaned volume password.
I can help delete these if you like, or you can clean them up later.
EOF
    if ui_confirm "Do you want to review them now?"; then
        cat <<EOF

I'll show one raw keychain entries (without the password) at a time.

EOF
        while test_keychain_by_label; do
            security find-generic-password -a "$NIX_VOLUME_LABEL"
            if ui_confirm "Can I delete this entry?"; then
                _sudo "to remove an old volume password from keychain" \
                security delete-generic-password -a "$NIX_VOLUME_LABEL"
            fi
        done
    else
        keychain_label_uninstall_directions
    fi
}

# the broad outline:
# --uninstall is complete (delete)
# the "curing" phase of install is like uninstall without removing /nix
# there should be some way of doing a full --uninstall-style curing, but idk what to call it
#   the simple way to do this is just supporting both --uninstall and --daemon or --no-daemon in a single invocation.
#
# uninstall
#   remove all of /nix
#   remove the volume and artifacts on darwin
#   delete ephemeral artifacts outside of Nix
#       sudo rm -rf /etc/nix /nix /var/root/.nix-profile /var/root/.nix-defexpr /var/root/.nix-channels /Users/<user>/.nix-profile /Users/<user>/.nix-defexpr /Users/<user>/.nix-channels
#
# repair/cure
#   replace volume artifacts
#   replace ephemeral artifacts outside of /nix
#       but leave /nix more-or-less intact
#
# reinstall? clean?
#   uninstall
#   install
#


# TODO: this needs a full vet now
# TODO: unused
volume_uninstall_prompt() {
    and_keychain=""
    # TODO: below needs UUID fed
    if test_keychain_by_uuid; then
        and_keychain=" (and its encryption key)"
    fi
    cat <<EOF

$NIX_VOLUME_USE_DISK already has a '$NIX_VOLUME_LABEL' volume, but the
installer is configured to create a new one.

I can delete the Nix volume if you're certain you don't need it. If
you want the installer to use your volume instead of creating one,
set 'NIX_VOLUME_CREATE=0'.

Here are the details of the Nix volume:
$(diskutil info "$NIX_VOLUME_LABEL")

EOF
    if password_confirm "delete this volume$and_keychain"; then
        if [ -n "$and_keychain" ]; then
            _sudo "to remove the volume password from keychain" \
                security delete-generic-password -s "$(volume_uuid "$NIX_VOLUME_LABEL")"
        fi
        # TODO: probably better ways to do diskID here now
        diskID="$(cache volume_special_device "$NIX_VOLUME_LABEL")"
        remove_volume "$diskID"
    else
        if [ -n "$and_keychain" ]; then
            keychain_uuid_uninstall_directions
        fi
        volume_uninstall_directions
    fi
}
keychain_uuid_uninstall_directions() {
    substep "Remove the volume password from keychain" \
      "  sudo security delete-generic-password -s '$(volume_uuid "$NIX_VOLUME_LABEL")'"
}
keychain_label_uninstall_directions() {
    substep "Remove the volume password from keychain" \
      "  sudo security delete-generic-password -a '$NIX_VOLUME_LABEL'"
}

setup_synthetic_conf() {
    if ! test_synthetic_conf_mountable; then
        task "Configuring /etc/synthetic.conf to make a mount-point at $NIX_ROOT" >&2
        # technically /etc/synthetic.d/nix is supported in Big Sur+
        # but handling both takes even more code...
        _sudo "to add Nix to /etc/synthetic.conf" \
            /usr/bin/ex /etc/synthetic.conf <<EOF
:a
${NIX_ROOT:1}
.
:x
EOF
        if ! test_synthetic_conf_mountable; then
            failure "error: failed to configure synthetic.conf" >&2
        fi
        create_synthetic_objects
        if ! test_nix; then
            failure "error: failed to bootstrap $NIX_ROOT" >&2
        fi
    fi
}

# TODO: review below, parts are obsolete now that I'm caving and using UUIDs
# fstab used to be responsible for mounting the volume. Now the last
# step adds a LaunchDaemon responsible for mounting. This is technically
# redundant for mounting, but diskutil appears to pick up mount options
# from fstab (and diskutil's support for specifying them directly is not
# consistent across versions/subcommands), enabling us to specify mount
# options by *label*.
#
# Being able to do all of this by label is helpful because it's a stable
# identifier that we can know at code-time, letting us skirt some logistic
# complexity that comes with doing this by UUID (which is stable, but not
# known ahead of time) or special device name/path (which is not stable).
#
# $1 = uuid
setup_fstab() {
    if ! test_fstab; then
        task "Configuring /etc/fstab to specify volume mount options" >&2
        add_nix_vol_fstab_line "$1" vifs
    fi
}
# $1 = uuid, $2 = label
encrypt_volume(){
    password="$(/usr/bin/xxd -l 32 -p -c 256 /dev/random)"
    _sudo "to add your Nix volume's password to Keychain" \
        /usr/bin/security -i <<EOF
add-generic-password -a "$2" -s "$1" -l "$2 encryption password" -D "Encrypted volume password" -j "Added automatically by the Nix installer for use by $NIX_VOLUME_MOUNTD_DEST" -w "$password" -T /System/Library/CoreServices/APFSUserAgent -T /System/Library/CoreServices/CSUserAgent -T /usr/bin/security "/Library/Keychains/System.keychain"
EOF
    builtin printf "%s" "$password" | _sudo "to encrypt your Nix volume" \
        diskutil apfs encryptVolume "$2" -user disk -stdinpassphrase
}
setup_volume() {
    task "Creating a Nix volume" >&2
    # DOING: I'm tempted to wrap this call in a grep to get the new disk special without doing anything too complex, but this sudo wrapper *is* a little complex, so it'll be a PITA unless maybe we can skip sudo on this. Let's just try it without.
    # Note: below may be fragile, but getting it from output here to
    # - save time over running slow diskutil commands
    # - skirt risk we grab wrong volume if multiple match
    new_special="$(/usr/sbin/diskutil apfs addVolume "$NIX_VOLUME_USE_DISK" "$NIX_VOLUME_FS" "$NIX_VOLUME_LABEL" -nomount | awk '/Created new APFS Volume/ {print $5}')"
    # TODO: clean/update below
    # _sudo "to create the Nix volume" \
    #     /usr/sbin/diskutil apfs addVolume "$NIX_VOLUME_USE_DISK" "$NIX_VOLUME_FS" "$NIX_VOLUME_LABEL" -nomount
    # Notes:
    # 1) using `-nomount` instead of `-mountpoint "$NIX_ROOT"` so to get
    # its UUID and set mount opts in fstab before first mount
    #
    # 2) system is in some sense less secure than user keychain... (it's
    # possible to read the password for decrypting the keychain) but
    # the user keychain appears to be available too late. As far as I
    # can tell, the file with this password (/var/db/SystemKey) is
    # inside the FileVault envelope. If that isn't true, it may make
    # sense to store the password inside the envelope?
    #
    # 3) At some point it would be ideal to have a small binary to serve
    # as the daemon itself, and for it to replace /usr/bin/security here.
    #
    # 4) *UserAgent exemptions should let the system seamlessly supply the
    # password if noauto is removed from fstab entry. This is intentional;
    # the user will hopefully look for help if the volume stops mounting,
    # rather than failing over into subtle race-condition problems.
    #
    # 5) If we ever get users griping about not having space to do
    # anything useful with Nix, it is possibly to specify
    # `-reserve 10g` or something, which will fail w/o that much
    new_uuid="$(/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -k "$new_special")"
    # TODO: new_uuid="$(volume_uuid "$NIX_VOLUME_LABEL")"

    setup_fstab "$new_uuid"

    if test_filevault_in_use; then
        encrypt_volume "$new_uuid" "$NIX_VOLUME_LABEL"
        setup_volume_daemon "encrypted" "$new_uuid"
    else
        setup_volume_daemon "unencrypted" "$new_uuid"
    fi
    # TODO: Loading the daemon will hopefully mount, but we'll make sure it
    # squeaks if not, and remove once we feel good.
    if ! _TODO_temp_test_mounted; then
        failure "Volume not mounted after voldaemon setup"
    fi
}
_TODO_temp_test_mounted() {
    diskutil info "$NIX_ROOT" | grep "Mounted:                   Yes"
}

# $1 == encrypted|unencrypted, $2 == uuid
setup_volume_daemon() {
    if ! test_voldaemon; then
        task "Configuring LaunchDaemon to mount '$NIX_VOLUME_LABEL'" >&2
        _sudo "to install the Nix volume mounter" /usr/bin/ex "$NIX_VOLUME_MOUNTD_DEST" <<EOF
:a
$(generate_mount_daemon "$1" "$2")
.
:x
EOF

        # TODO: should probably alert the user if this is disabled?
        # TODO: confirm this runs the service; if not we may want to
        # kickstart it
        _sudo "to launch the Nix volume mounter" \
            /bin/launchctl bootstrap system "$NIX_VOLUME_MOUNTD_DEST"
    fi
}

setup_darwin_volume() {
    setup_synthetic_conf
    setup_volume
}

if [ "$_CREATE_VOLUME_NO_MAIN" = 1 ]; then
    if [ -n "$*" ]; then
        "$@" # expose functions in case we want multiple routines?
    fi
else
    # no reason to pay for bash to process this
    main() {
        {
            echo ""
            echo "     ------------------------------------------------------------------ "
            echo "    | This installer will create a volume for the nix store and        |"
            echo "    | configure it to mount at $NIX_ROOT.  Follow these steps to uninstall. |"
            echo "     ------------------------------------------------------------------ "
            echo ""
            echo "  1. Remove the entry from fstab using 'sudo vifs'"
            echo "  2. Run 'sudo launchctl bootout system/org.nixos.darwin-store'"
            echo "  3. Remove $NIX_VOLUME_MOUNTD_DEST"
            echo "  4. Destroy the data volume using 'diskutil apfs deleteVolume'"
            echo "  5. Remove the 'nix' line from /etc/synthetic.conf (or the file)"
            echo ""
        } >&2

        if test_nix_symlink; then
            failure >&2 <<EOF
error: $NIX_ROOT is a symlink (-> $(readlink "$NIX_ROOT")).
Please remove it. If nix is in /etc/synthetic.conf, remove it and reboot.
EOF
        fi

        setup_darwin_volume
    }

    main "$@"
fi

# DOING/META: YOU WANT TO TEST INSTALLING WITH THE LIVE INSTALLER IN SINGLE-USER MODE AND THEN INSTALLING OVER IT WITH THIS ONE. FOR IT TO WORK LIKE YOU WANT, YOU NEED TO IMPLEMENT:
# 1.) HANDLE THE OLD-STYLE VOLUME
# 2.) KEEP THE VOLUME

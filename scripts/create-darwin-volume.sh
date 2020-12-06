#!/usr/bin/env bash
set -eu

# I'm a little agnostic on the choices, but supporting a wide
# slate of uses for now, including:
# - import-only: `. create-darwin-volume.sh no-main[ ...]`
# - legacy: `./create-darwin-volume.sh` or `. create-darwin-volume.sh`
#   (both will run main())
# - external alt-routine: `./create-darwin-volume.sh no-main func[ ...]`
if [ "${1-}" = "no-main" ]; then
    shift
    readonly _CREATE_VOLUME_NO_MAIN=1
else
    readonly _CREATE_VOLUME_NO_MAIN=0
    # declare some things we expect to inherit from install-multi-user
    # I don't love this (because it's a bit of a kludge)
    readonly NIX_ROOT="${NIX_ROOT:-/nix}"

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

# usually "disk1"
root_disk_identifier() {
    # For performance (~10ms vs 280ms) I'm parsing 'diskX' from stat output
    # (~diskXsY)--but I'm retaining the more-semantic approach since
    # it documents intent better.
    # /usr/sbin/diskutil info -plist / | xmllint --xpath "/plist/dict/key[text()='ParentWholeDisk']/following-sibling::string[1]/text()" -
    #
    local special_device
    special_device="$(/usr/bin/stat -f "%Sd" /)"
    echo "${special_device%s[0-9]*}"
}

# make it easy to play w/ 'Case-sensitive APFS'
readonly NIX_VOLUME_FS="${NIX_VOLUME_FS:-APFS}"
readonly NIX_VOLUME_LABEL="${NIX_VOLUME_LABEL:-Nix Store}"
# Strongly assuming we'll make a volume on the device / is on
# But you can override NIX_VOLUME_USE_DISK to create it on some other device
readonly NIX_VOLUME_USE_DISK="${NIX_VOLUME_USE_DISK:-$(root_disk_identifier)}"
NIX_VOLUME_USE_SPECIAL="${NIX_VOLUME_USE_SPECIAL:-}"
NIX_VOLUME_USE_UUID="${NIX_VOLUME_USE_UUID:-}"
readonly NIX_VOLUME_MOUNTD_DEST="${NIX_VOLUME_MOUNTD_DEST:-/Library/LaunchDaemons/org.nixos.darwin-store.plist}"

if /usr/bin/fdesetup isactive >/dev/null; then
    test_filevault_in_use() { return 0; }
    # no readonly; we may modify if user refuses from cure_volume
    NIX_VOLUME_DO_ENCRYPT="${NIX_VOLUME_DO_ENCRYPT:-1}"
else
    test_filevault_in_use() { return 1; }
    NIX_VOLUME_DO_ENCRYPT="${NIX_VOLUME_DO_ENCRYPT:-0}"
fi

should_encrypt_volume() {
    test_filevault_in_use && (( NIX_VOLUME_DO_ENCRYPT == 1 ))
}

substep() {
    printf "   %s\n" "" "- $1" "" "${@:2}"
}

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
    <xsl:text>=</xsl:text>
    <xsl:apply-templates match="string" select="key[text()='UUID']/following-sibling::*[1]"/>
    <xsl:text>&#xA;</xsl:text>
  </xsl:template>
</xsl:stylesheet>
EOF
    # I cut label out of the extracted values, but here it is for reference:
    # <xsl:apply-templates match="string" select="key[text()='IORegistryEntryName']/following-sibling::*[1]"/>
    # <xsl:text>=</xsl:text>
}

# $1 = volume special (i.e., disk1s7)
right_disk() {
    [[ "$1" == "$NIX_VOLUME_USE_DISK"s* ]]
}
# $1 = volume special (i.e., disk1s7)
right_volume() {
    # if set, it must match; otherwise ensure it's on the right disk
    if [ -z "$NIX_VOLUME_USE_SPECIAL" ]; then
        if right_disk "$1"; then
            NIX_VOLUME_USE_SPECIAL="$1" # latch on
            return 0
        else
            return 1
        fi
    else
        [ "$1" = "$NIX_VOLUME_USE_SPECIAL" ]
    fi
}
# $1 = volume uuid
right_uuid() {
    # if set, it must match; otherwise allow
    if [ -z "$NIX_VOLUME_USE_UUID" ]; then
        NIX_VOLUME_USE_UUID="$1" # latch on
        return 0
    else
        [ "$1" = "$NIX_VOLUME_USE_UUID" ]
    fi
}

cure_volumes() {
    local found volume special uuid
    # loop just in case they have more than one volume
    # (nothing stops you from doing this)
    for volume in $(volumes_labeled "$NIX_VOLUME_LABEL"); do
        # CAUTION: this could (maybe) be a more normal read
        # loop like:
        #   while IFS== read -r special uuid; do
        #       # ...
        #   done <<<"$(volumes_labeled "$NIX_VOLUME_LABEL")"
        #
        # I did it with for to skirt a problem with the obvious
        # pattern replacing stdin and causing user prompts
        # inside (which also use read and access stdin) to skip
        #
        # If there's an existing encrypted volume we can't find
        # in keychain, the user never gets prompted to delete
        # the volume, and the install fails.
        #
        # If you change this, a human needs to test a very
        # specific scenario: you already have an encrypted
        # Nix Store volume, and have deleted its credential
        # from keychain. Ensure the script asks you if it can
        # delete the volume, and then prompts for your sudo
        # password to confirm.
        #
        # shellcheck disable=SC1097
        IFS== read -r special uuid <<< "$volume"
        # take the first one that's on the right disk
        if [ -z "$found" ]; then
            if right_volume "$special" && right_uuid "$uuid"; then
                cure_volume "$special" "$uuid"
                found="${special} (${uuid})"
            else
                warning <<EOF
Ignoring ${special} (${uuid}) because I am looking for:
disk=${NIX_VOLUME_USE_DISK} special=${NIX_VOLUME_USE_SPECIAL:-${NIX_VOLUME_USE_DISK}sX} uuid=${NIX_VOLUME_USE_UUID:-any}
EOF
                # TODO: give chance to delete if ! headless?
            fi
        else
            warning <<EOF
Ignoring ${special} (${uuid}), already found target: $found
EOF
            # TODO reminder? I feel like I want one
            # idiom that reminds some warnings, or warns
            # some reminders?
            # TODO: if ! headless, chance to delete?
        fi
    done
    if [ -z "$found" ]; then
        readonly NIX_VOLUME_USE_SPECIAL NIX_VOLUME_USE_UUID
    fi
}

# $1 = special
volume_encrypted() {
    # Trying to match the first line of output; known first lines:
    # No cryptographic users for <special>
    # Cryptographic user for <special> (1 found)
    # Cryptographic users for <special> (2 found)
    diskutil apfs listCryptoUsers "$1" | /usr/bin/grep -q "Cryptographic users* for $1 ([0-9]* found)"
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

# current volume password
# $1 = uuid
test_keychain_by_uuid() {
    # Note: doesn't need sudo just to check; doesn't output pw
    security find-generic-password -s "$1" &>/dev/null
}

# $1 = uuid
get_volume_pass() {
    _sudo \
        "to confirm keychain has a password that unlocks this volume" \
        security find-generic-password -s "$1" -w
}

# $1 = special device, $2 = uuid
verify_volume_pass() {
    diskutil apfs unlockVolume "$1" -verify -stdinpassphrase -user "$2"
}

# $1 = special device, $2 = uuid
volume_pass_works() {
    get_volume_pass "$2" | verify_volume_pass "$1" "$2"
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

_eat_bootout_err() {
    /usr/bin/grep -v "Boot-out failed: 36: Operation now in progress" 1>&2
}

# TODO: remove with --uninstall?
uninstall_launch_daemon_directions() {
    substep "Uninstall LaunchDaemon $1" \
      "  sudo launchctl bootout system/$1" \
      "  sudo rm $2"
}

uninstall_launch_daemon_prompt() {
    cat <<EOF

The installer adds a LaunchDaemon to $3: $1
EOF
    if ui_confirm "Can I remove it?"; then
        _sudo "to terminate the daemon" \
            launchctl bootout "system/$1" 2> >(_eat_bootout_err) || true
            # this can "fail" with a message like:
            # Boot-out failed: 36: Operation now in progress
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

# TODO: move nix_daemon to install-darwin-multi-user if/when uninstall_launch_daemon_prompt moves up to install-multi-user
nix_daemon_uninstall_prompt() {
    uninstall_launch_daemon_prompt "org.nixos.nix-daemon" \
        "$NIX_DAEMON_DEST" \
        "run the nix-daemon"
}

# TODO: remove with --uninstall?
nix_daemon_uninstall_directions() {
    uninstall_launch_daemon_directions "org.nixos.nix-daemon" \
        "$NIX_DAEMON_DEST"
}


# TODO: remove with --uninstall?
synthetic_conf_uninstall_directions() {
    # :1 to strip leading slash
    substep "Remove ${NIX_ROOT:1} from /etc/synthetic.conf" \
        "  If nix is the only entry: sudo rm /etc/synthetic.conf" \
        "  Otherwise: grep -v '^${NIX_ROOT:1}$' /etc/synthetic.conf | sudo dd of=/etc/synthetic.conf"
}

synthetic_conf_uninstall_prompt() {
    cat <<EOF
During install, I add '${NIX_ROOT:1}' to /etc/synthetic.conf, which instructs
macOS to create an empty root directory for mounting the Nix volume.
EOF
    # there are a few things we can do here
    # 1. if grep -v didn't match anything (also, if there's no diff), we know this is moot
    # 2. if grep -v was empty (but did match?) I think we know that we can just remove the file
    # 3. if the edit doesn't ~empty the file, show them the diff and ask
    if ! /usr/bin/grep -v '^'"${NIX_ROOT:1}"'$' /etc/synthetic.conf > "$SCRATCH/synthetic.conf.edit"; then
        if confirm_rm "/etc/synthetic.conf"; then
            return 0
        fi
    else
        if /usr/bin/cmp <<<"" "$SCRATCH/synthetic.conf.edit"; then
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
    local uuid="$1"
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
    #   that I don't understand yet
    #   (Note however that I've had to add a chown step to handle
    #   single->multi-user reinstalls, which may cover this)
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
    #
    # TODO: when this is workable, poke infinisil about reproducing the issue
    # and confirming this fix?
}

delete_nix_vol_fstab_line() {
    # TODO: I'm scaffolding this to handle the new nix volumes
    # but it might be nice to generalize a smidge further to
    # go ahead and set up a pattern for curing "old" things
    # we no longer do?
    EDITOR="/usr/bin/patch" _sudo "to cut nix from fstab" "$@" < <(/usr/bin/diff /etc/fstab <(/usr/bin/grep -v "$NIX_ROOT apfs rw" /etc/fstab))
    # leaving some parts out of the grep; people may fiddle this a little?
}

# TODO: hope to remove with --uninstall
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
    if /usr/bin/diff -q <(:) <(/usr/bin/grep -v "^#" "$SCRATCH/fstab.edit") &>/dev/null; then
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
    header "Found existing Nix volume"
    row "  special" "$1"
    row "     uuid" "$2"

    if volume_encrypted "$1"; then
        row "encrypted" "yes"
        if volume_pass_works "$1" "$2"; then
            NIX_VOLUME_DO_ENCRYPT=0
            ok "Found a working decryption password in keychain :)"
            echo ""
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
"Where" (service) field set to this volume's UUID:
  $2
EOF
            if password_confirm "delete this volume"; then
                remove_volume "$1"
            else
                # TODO: this is a good design case for a warn-and
                # remind idiom...
                failure <<EOF
Your Nix volume is encrypted, but I couldn't find its password. Either:
- Delete or rename the volume out of the way
- Ensure its decryption password is in the system keychain with a
  "Where" (service) field set to this volume's UUID:
    $2
EOF
            fi
        fi
    elif test_filevault_in_use; then
        row "encrypted" "no"
        warning <<EOF
FileVault is on, but your $NIX_VOLUME_LABEL volume isn't encrypted.
EOF
        # if we're interactive, give them a chance to
        # encrypt the volume. If not, /shrug
        if ! headless && (( NIX_VOLUME_DO_ENCRYPT == 1 )); then
            if ui_confirm "Should I encrypt it and add the decryption key to your keychain?"; then
                encrypt_volume "$2" "$NIX_VOLUME_LABEL"
            else
                NIX_VOLUME_DO_ENCRYPT=0
                reminder "FileVault is on, but your $NIX_VOLUME_LABEL volume isn't encrypted."
            fi
        fi
    else
        row "encrypted" "no"
    fi
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

    if test_nix_volume_mountd_installed; then
        nix_volume_mountd_uninstall_prompt
    fi
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

# $1 = uuid
setup_fstab() {
    # fstab used to be responsible for mounting the volume. Now the last
    # step adds a LaunchDaemon responsible for mounting. This is technically
    # redundant for mounting, but diskutil appears to pick up mount options
    # from fstab (and diskutil's support for specifying them directly is not
    # consistent across versions/subcommands).
    if ! test_fstab; then
        task "Configuring /etc/fstab to specify volume mount options" >&2
        add_nix_vol_fstab_line "$1" vifs
    fi
}

# $1 = uuid, $2 = label
encrypt_volume() {
    local password
    # Note: mount/unmount are late additions to support the right order
    # of operations for creating the volume and then baking its uuid into
    # other artifacts; not as well-trod wrt to potential errors, race
    # conditions, etc.
    diskutil mount "$2"

    password="$(/usr/bin/xxd -l 32 -p -c 256 /dev/random)"
    _sudo "to add your Nix volume's password to Keychain" \
        /usr/bin/security -i <<EOF
add-generic-password -a "$2" -s "$1" -l "$2 encryption password" -D "Encrypted volume password" -j "Added automatically by the Nix installer for use by $NIX_VOLUME_MOUNTD_DEST" -w "$password" -T /System/Library/CoreServices/APFSUserAgent -T /System/Library/CoreServices/CSUserAgent -T /usr/bin/security "/Library/Keychains/System.keychain"
EOF
    builtin printf "%s" "$password" | _sudo "to encrypt your Nix volume" \
        diskutil apfs encryptVolume "$2" -user disk -stdinpassphrase

    diskutil unmount force "$2"
}

create_volume() {
    # Notes:
    # 1) using `-nomount` instead of `-mountpoint "$NIX_ROOT"` to get
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
    #
    # 6) getting special w/ awk may be fragile, but doing it to:
    #    - save time over running slow diskutil commands
    #    - skirt risk we grab wrong volume if multiple match
    diskutil apfs addVolume "$NIX_VOLUME_USE_DISK" "$NIX_VOLUME_FS" "$NIX_VOLUME_LABEL" -nomount | /usr/bin/awk '/Created new APFS Volume/ {print $5}'
}

# $1 = volume special
volume_uuid_from_special() {
    # For reasons I won't pretend to fathom, this returns 253 when it works
    /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -k "$1" || true
}

# this sometimes clears immediately, and AFAIK clears
# within about 1s. diskutil info on an unmounted path
# fails in around 50-100ms and a match takes about
# 250-300ms. I suspect it's usually ~250-750ms
await_volume() {
    # caution: this could, in theory, get stuck
    until diskutil info "$NIX_ROOT" &>/dev/null; do
        :
    done
}

setup_volume() {
    local use_special use_uuid profile_packages
    task "Creating a Nix volume" >&2
    # DOING: I'm tempted to wrap this call in a grep to get the new disk special without doing anything too complex, but this sudo wrapper *is* a little complex, so it'll be a PITA unless maybe we can skip sudo on this. Let's just try it without.

    use_special="${NIX_VOLUME_USE_SPECIAL:-$(create_volume)}"

    use_uuid=${NIX_VOLUME_USE_UUID:-$(volume_uuid_from_special "$use_special")}

    setup_fstab "$use_uuid"

    if should_encrypt_volume; then
        encrypt_volume "$use_uuid" "$NIX_VOLUME_LABEL"
        setup_volume_daemon "encrypted" "$use_uuid"
    # TODO: might be able to save ~60ms by caching or setting
    # this somewhere rather than re-checking here.
    elif volume_encrypted "$use_special"; then
        setup_volume_daemon "encrypted" "$use_uuid"
    else
        setup_volume_daemon "unencrypted" "$use_uuid"
    fi

    await_volume

    # TODO: below is a vague kludge for now; I just don't know
    # what if any safe action there is to take here. Also, the
    # reminder isn't very helpful.
    # I'm less sure where this belongs, but it also wants mounted, pre-install
    if type -p nix-env; then
        profile_packages="$(nix-env --query --installed)"
        # TODO: can probably do below faster w/ read
        # intentionally unquoted string to eat whitespace in wc output
        # shellcheck disable=SC2046,SC2059
        if ! [ $(printf "$profile_packages" | /usr/bin/wc -l) = "0" ]; then
            reminder <<EOF
Nix now supports only multi-user installs on Darwin/macOS, and your user's
Nix profile has some packages in it. These packages may obscure those in the
default profile, including the Nix this installer will add. You should
review these packages:
$profile_packages
EOF
        fi
    fi

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
        _sudo "to launch the Nix volume mounter" \
            launchctl bootstrap system "$NIX_VOLUME_MOUNTD_DEST" || true
        # TODO: confirm whether kickstart is necessesary?
        # I feel a little superstitous, but it can guard
        # against multiple problems (doesn't start, old
        # version still running for some reason...)
        _sudo "to launch the Nix volume mounter" \
            launchctl kickstart -k system/org.nixos.darwin-store
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

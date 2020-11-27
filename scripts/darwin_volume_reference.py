"""
~python pseudocode to outline the PR's logic
and how to build an uninstaller atop it later

just for reference; I'll drop this before merge
"""

# overridable from env
NIX_VOLUME_USE_DISK = "disk1"


def remove_nix_artifacts():
    """remove everything outside of /nix"""
    raise NotImplementedError("Future work")


def remove_nix_dir():
    """remove /nix"""
    raise NotImplementedError("Future work")


def remove_volume():  # LATER/LONG-TERM
    if user_consents:
        if volume.encrypted:
            remove_encryption_password_from_keychain()
        volume.delete()
    else:
        exit()


def remove_nix():  # LATER/LONG-TERM
    if darwin and needs_volume:
        remove_volume()
        remove_volume_artifacts()
    else:
        remove_nix_dir()

    remove_nix_artifacts()


def encrypt_volume(volume):
    generate_encryption_password
    add_encryption_password_to_keychain
    volume.encrypt()


def add_volume_artifacts():
    add_to_synthetic_conf
    create_mountpoint
    add_to_fstab
    create_volume
    if filevault_in_use:
        encrypt_volume(volume)

    create_mounter_daemon


def remove_volume_artifacts():
    remove_from_synthetic_conf()
    remove_from_fstab()
    remove_volume_mounter()


def cure_volume(volume):
    if volume.encrypted:
        if volume.pw_in_keychain and volume.pw_works:
            pass
        else:
            # we don't have access to the password so
            # prompt them to remove it, but say they
            # can add the credential to keychain and
            # retry (in case it's named wrong, etc.)
            if user_consents:
                volume.delete()
    elif filevault_in_use:
        # warn user FV is on but vol not encrypted
        if not headless:
            if user_consents:
                encrypt_volume(volume)


def cure_volumes():
    for volume in volumes_labeled("Nix Store"):
        if volume.disk == NIX_VOLUME_USE_DISK:
            cure_volume(volume)


def cure_artifacts():
    # env can override needs_volume
    if darwin and needs_volume:
        cure_volumes()
        remove_volume_artifacts()

    # remove_nix_artifacts() (LATER)


def install_single_user():
    ...  # existing process


def install_multi_user():
    if darwin and needs_volume:
        add_volume_artifacts()
    ...  # existing process


def installer(*args):
    """
  Short-term call patterns unchanged:

  ./installer
    note: macOS now defaults to multi-user
  ./installer --daemon
  ./installer --no-daemon
    note: disabled for macOS

  Later, add two kinds of uninstall. Simple:
  ./installer --uninstall

  And single-step uninstall + install. could be
  a separate flag, but I'm imagining:

  ./installer --uninstall --daemon
  ./installer --uninstall --no-daemon
  """

    # LATER/LONG-TERM
    # if "--uninstall" in args:
    #     remove_nix()

    if "--no-daemon" in args:
        if darwin:
            exit()

        if "--uninstall" not in args:
            cure_artifacts()

        install_single_user()
    elif "--daemon" in args:
        if "--uninstall" not in args:
            cure_artifacts()
        install_multi_user()
    else:
        if "--uninstall" not in args:
            cure_artifacts()

        if darwin:
            install_multi_user()
        else:
            install_single_user()

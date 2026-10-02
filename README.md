# homelab

## Media verification

On an x86_64 Linux builder with KVM, `nix build .#checks.x86_64-linux.media-runtime -L` runs the pinned media services in a disposable Docker VM without production mounts or credentials.

Native service behavior is the category-integration proof. SABnzbd owns its default `*` category; the local initializer checks must not equate its complete category inventory with the configured Arr instances.
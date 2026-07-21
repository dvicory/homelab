# Reviewed network bundle catalog (V3 §12.2).
#
# Initial bundles cover only hosts proved necessary by representative Git,
# npm, PyPI, and Nix operations. Completeness is defined by target-host
# tests, not guessed host lists. Additions require a test of the operation
# they unblock and review of the authority/data combination (§21).
{ net }:

{
  # Git smart-HTTP over HTTPS against GitHub: refs, pack negotiation, and
  # LFS/archive payloads.
  git-public = net.bundle {
    destinations = [
      (net.httpsExact "github.com")
      (net.httpsExact "codeload.github.com")
      (net.httpsExact "api.github.com")
      (net.httpsExact "objects.githubusercontent.com")
      (net.httpsExact "github-releases.githubusercontent.com")
    ];
  };

  # npm registry metadata and tarballs.
  npm-public = net.bundle {
    destinations = [
      (net.httpsExact "registry.npmjs.org")
    ];
  };

  # PyPI index and package files.
  pypi-public = net.bundle {
    destinations = [
      (net.httpsExact "pypi.org")
      (net.httpsExact "files.pythonhosted.org")
    ];
  };

  # NixOS binary cache and channel metadata.
  nix-cache-public = net.bundle {
    destinations = [
      (net.httpsExact "cache.nixos.org")
      (net.httpsExact "channels.nixos.org")
    ];
  };
}

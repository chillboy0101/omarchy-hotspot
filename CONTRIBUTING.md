# Contributing to Omarchy Hotspot

Thanks for your interest in contributing! This document will help you get started.

## How to contribute

### Reporting bugs

Found a bug? Please [open an issue](https://github.com/shivamnarkar47/omarchy-hotspot/issues/new?template=bug_report.md) and include:

- A clear description of what went wrong
- Steps to reproduce the issue
- Your environment (Omarchy version, kernel, Wi-Fi card/chipset)
- Relevant logs (`journalctl -u omarchy-hotspot`, `journalctl -u omarchy-hotspot-dns`)
- A screenshot if applicable

### Suggesting features

Have an idea? Open an issue describing the feature and why it would be useful. Check existing issues first to avoid duplicates.

### Pull requests

1. **Fork** the repository and create a branch from `main`
2. **Reference the issue** in your PR description (e.g., "Fixes #3")
3. **Describe what you changed and why** — include testing steps you performed
4. **Keep changes focused** — one feature or fix per PR
5. **Sync with the base branch** before requesting review

## Development setup

```sh
# Clone your fork
git clone https://github.com/YOUR_USERNAME/omarchy-hotspot.git
cd omarchy-hotspot

# Install dependencies (Arch Linux)
sudo pacman -S hostapd dnsmasq iw nmcli qrencode shellcheck

# Validate the plugin manifest
omarchy plugin validate

# Run shellcheck on the helper
shellcheck src/omarchy-hotspot-helper

# Syntax check
bash -n src/omarchy-hotspot-helper
```

## Code style

### Shell scripts (`src/omarchy-hotspot-helper`)

- Follow existing patterns — consistency matters
- Pass `shellcheck` with no errors
- Use `set -euo pipefail` at the top of scripts
- Quote variables properly
- Keep functions focused and readable

### QML (`plugin/Panel.qml`)

- Follow the existing structure and naming conventions
- Keep UI logic in the QML layer, system operations in the helper
- Test with various content lengths to avoid layout overflow

## Testing

Currently there is no automated test suite. For now:

- **Manually test** your changes on a real system
- **Verify** `shellcheck` and `bash -n` pass
- **Document** the testing steps in your PR description
- For helper changes, verify with `dnsmasq --test` when touching dnsmasq arguments

## Code of conduct

Be respectful and constructive. We're all here to build something useful together.

## Questions?

Open an issue and ask. We're happy to help you get started.

## Contributors

Thanks to everyone who has helped improve this project:

| Contributor | Role |
|---|---|
| **[Shivam Narkar](https://github.com/shivamnarkar47)** — `@shivamnarkar47` | Creator & maintainer |
| **[Muhammad Dicky Isra](https://github.com/DaDecky)** — `@DaDecky` | Contributor (scoped IPv6 resolver fix) |
| **[JunaidIRF](https://github.com/JunaidIRF)** — `@JunaidIRF` | Contributor (inline SSID editor & popup overflow fix) |

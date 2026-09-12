# Router-grade device identification design

## Goal

Show the most useful truthful name available for each hotspot client while keeping the popup fast and visually native to Omarchy.

## Evidence and constraint

The connected phone currently supplies no DHCP hostname, publishes no resolvable mDNS name, uses a MAC-only DHCP client ID, and enables the locally administered bit on its randomized MAC. The laptop therefore cannot recover the phone's Settings name from the current lease. Router products handle this with several discovery sources and remembered aliases; automatic identification alone cannot guarantee a name when a client withholds it.

## Resolution order

1. User-assigned alias stored locally for the client MAC.
2. DHCP option 12 hostname captured when the lease is created.
3. Cached mDNS reverse name.
4. NetBIOS name for clients that support it.
5. OUI manufacturer for globally administered MAC addresses.
6. `Unknown device` when no truthful identity exists.

The MAC address, IP address, signal strength, and connected duration remain supporting details. No internet lookup, OS fingerprint scan, packet capture, or guessed phone model is allowed.

Device names and aliases preserve valid UTF-8, including emoji and non-Latin characters. Control characters and tab/newline field separators are removed. Long names wrap naturally in the flexible device column so the complete label remains visible without pushing signal strength or connection time outside the panel.

## Architecture

`dnsmasq` calls a small lease-event script that records the hostname, vendor class, client ID, MAC, and IP in a root-owned runtime cache. A new or changed lease schedules discovery once and caches the result; the normal 1.5-second panel refresh performs no network lookup. The existing device-identification library reads that cache and performs short, bounded local mDNS and NetBIOS lookups. User aliases live in a persistent user-readable file managed by narrowly scoped helper subcommands.

The panel receives tab-separated fields from `helper clients` and renders a native Omarchy device row. An edit action beside each row opens a compact alias field using `TextField` and unboxed `PanelActionButton` controls. Saving an empty alias removes it. Discovery runs outside QML and uses cached results so opening and switching panels remains immediate.

## Security and privacy

- Sanitize all DHCP-provided strings and render them as `Text.PlainText`.
- Accept aliases only over stdin, never process arguments.
- Limit aliases to 1-48 Unicode characters; preserve valid UTF-8 and emoji, reject control characters and separators, and treat blank as delete.
- Keep persistent aliases mode `600` and runtime discovery data mode `600`.
- Do not add external services, telemetry, fingerprinting, or internet requests.

## Success criteria

- A fixture with a DHCP hostname displays that hostname.
- A fixture without a hostname can resolve from mDNS, NetBIOS, or OUI in order.
- A privacy-randomized phone remains `Unknown device` until the user assigns an alias.
- A saved alias appears immediately and survives hotspot and shell restarts.
- Repeated device refreshes perform no mDNS or NetBIOS lookup and do not delay panel transitions.
- Names containing emoji and non-Latin characters render intact.
- Existing hotspot, QR, credential editing, and device timing tests continue to pass.

# Raspberry Pi 4 — AdGuard Home DNS + Unbound recursive resolver
#
# One of two independent DNS paths. This host resolves for itself and depends
# on no other host, as does core4, so either can serve the LAN alone. It
# replaced core3, which ran AdGuard only and forwarded to core4's Unbound —
# making core4 a single point of failure for both paths.
#
# A resolver because lib/net.nix lists it in `resolvers`: hosts/common imports
# hosts/common/resolver.nix, which holds everything lifeline and core4 share.
{ }

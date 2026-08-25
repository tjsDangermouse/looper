# GraphHopper deployment asset

This directory packages the self-hosted GraphHopper instances used exclusively
by the Looper Route Service. It is routing-service infrastructure, not a web
or iOS dependency.

Compose configuration lives beside this directory because it joins the service
and its two regional routing graphs for local and production runs. This is
already the routing-service extraction boundary. See the route service
[README](../README.md) for ownership and run commands.

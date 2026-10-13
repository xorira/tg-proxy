# The operator site is deliberately not here

`tproxy-server` asks the operator to supply a real website that the relay serves
from memory while the transport hides behind a path prefix.

This repository does **not** ship one, and neither should a public fork. From the
upstream documentation:

> The repository deliberately does not include a deployable public website. If
> many operators installed the same starter, its body and assets would become an
> easy active-probing signature.

A shared starter makes every deployment that copied it identifiable by a single
request. Write your own site, or point `public_upstream` at an application that
already exists for its own reasons.

`public_dir` and `public_upstream` are mutually exclusive: exactly one of them
must be set.

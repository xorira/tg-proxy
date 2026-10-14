# Placeholder site — replace it

The relay disguises itself as an ordinary website and serves one from memory. This
directory holds a deliberately generic stand-in so the image can be started for a
first test without preparation.

**Do not operate with it.** Upstream is explicit:

> The repository deliberately does not include a deployable public website. If many
> operators installed the same starter, its body and assets would become an easy
> active-probing signature.

Every deployment running this exact page is identifiable by one request. Write
your own site — a few pages are plenty — and mount it:

```bash
docker run ... -v /srv/my-site:/srv/tproxy-site:ro
```

The entrypoint refuses to fall back to this placeholder unless you pass
`-e ALLOW_PLACEHOLDER_SITE=yes`, precisely so that the default is the safe one.

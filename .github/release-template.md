### Upgrading

```bash
# Install the latest version of Tailscale UniFi
curl -sSLq https://raw.githubusercontent.com/{{ repo }}/refs/tags/{{ tag }}/install.sh | sh

# Then run the following to complete the update
/data/tailscale/manage.sh install!
```

{{ changelog }}

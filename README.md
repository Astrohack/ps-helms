install dependencies:

```bash
mise install
```

run:

```bash
just cluster-create single
just setup-sops
just inject-sops-key
just generate-and-inject-tls
just bootstrap
```

# sprites-scripts
Some Tools I use to setup my sprites

## Github

### setup key access to repo

These script works when you have already setup [connectors](https://docs.sprites.dev/concepts/connectors/)

Setup access to a repo (direct curl, trust me, RW default)

```bash
curl -s "https://raw.githubusercontent.com/peterw22/sprites-scripts/refs/heads/main/scripts/github/ssh_key.py" | python3 - OWNER/REPO
```

Access to a repo (Read only)

```bash
curl -s "https://raw.githubusercontent.com/peterw22/sprites-scripts/refs/heads/main/scripts/github/ssh_key.py" \
  | READ_ONLY=true python3 - OWNER/REPO
```

Remove access to a repo (Clean up is always good, key dont expire by default)

```bash
curl -s "https://raw.githubusercontent.com/peterw22/sprites-scripts/refs/heads/main/scripts/github/ssh_key.py" | python3 - --remove OWNER/REPO
```
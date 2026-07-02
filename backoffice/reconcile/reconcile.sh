#!/usr/bin/env bash
# Pull-based GitOps reconciler for the backoffice Docker Swarm (ArgoCD-style loop).
# Run by a systemd timer. Updates the repo, SOPS-decrypts each stack's secrets, and
# `docker stack deploy`s every stack under backoffice/stacks/.
#
# On-box prereqs (bootstrap once):
#   /etc/infra/age.key            - SOPS age private key
#   /etc/infra/ssh/id_rsa         - git deploy key (read)
#   /etc/infra/ssh/known_hosts    - github host key
#   installed at /usr/local/bin/infra-reconcile.sh + infra-reconcile.{service,timer}
set -euo pipefail

REPO_URL="git@github.com:YOUR_ORG/infra.git"
REPO_DIR="/opt/infra"
BRANCH="master"
STACKS_SUBDIR="backoffice/stacks"

export SOPS_AGE_KEY_FILE="/etc/infra/age.key"
export GIT_SSH_COMMAND="ssh -i /etc/infra/ssh/id_rsa -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/infra/ssh/known_hosts"

log() { echo "$(date -u +%FT%TZ) reconcile: $*"; }

# 1. sync repo
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
  git -C "$REPO_DIR" reset --hard --quiet "origin/$BRANCH"
else
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi
log "repo at $(git -C "$REPO_DIR" rev-parse --short HEAD)"

# 1b. self-update: keep the installed script + units in sync with the repo (GitOps for itself)
SELF="$REPO_DIR/backoffice/reconcile"
install -m755 "$SELF/reconcile.sh" /usr/local/bin/infra-reconcile.sh
if ! cmp -s "$SELF/infra-reconcile.service" /etc/systemd/system/infra-reconcile.service \
   || ! cmp -s "$SELF/infra-reconcile.timer" /etc/systemd/system/infra-reconcile.timer; then
  cp "$SELF/infra-reconcile.service" "$SELF/infra-reconcile.timer" /etc/systemd/system/
  systemctl daemon-reload || true
fi

# 2. ensure the shared edge network exists (traefik also declares it)
docker network inspect traefik-public >/dev/null 2>&1 || \
  docker network create --driver overlay --attachable traefik-public >/dev/null

# 3. reconcile each stack
cd "$REPO_DIR/$STACKS_SUBDIR"
for dir in */; do
  name="${dir%/}"
  [ -f "${dir}stack.yml" ] || continue
  # decrypt SOPS secrets: *.sops -> same name without the .sops suffix
  for f in "$dir"*.sops; do
    [ -f "$f" ] || continue
    sops --decrypt --input-type binary --output-type binary "$f" > "${f%.sops}"
  done
  log "deploying stack '$name'"
  # source any decrypted *.env so `docker stack deploy` can interpolate ${VARS} in stack.yml
  # (Swarm ignores env_file; this is how a stack gets secret env, e.g. gatus SMTP_PASSWORD)
  (
    cd "$dir"
    set -a
    for e in *.env; do [ -f "$e" ] && . "./$e"; done
    # Content hash of the stack's non-secret files (config.yaml, stack.yml, ...). Exported so a
    # stack can pin it into a container env/label and force a redeploy when its config changes —
    # a bind-mounted file's *content* changing is otherwise NOT a Swarm spec change, so the task
    # never restarts and keeps stale config (the gatus reload bug). See gatus/stack.yml RECONCILE_HASH.
    STACK_HASH=$(find . -maxdepth 1 -type f ! -name '*.sops' ! -name '*.env' -print0 \
      | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-12)
    set +a
    docker stack deploy --detach=true --resolve-image=always -c stack.yml "$name"
  )
done
log "done"

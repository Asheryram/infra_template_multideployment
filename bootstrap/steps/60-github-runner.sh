#!/usr/bin/env bash
# Optional: GitHub Actions self-hosted runner, running as the deploy user.
# The runner polls GitHub (outbound only), so no inbound SSH or deploy keys are
# needed, and it works on a laptop VM too. Only the *deploy* job runs here;
# image builds stay on GitHub-hosted runners.
#
# Use an ORGANISATION-level runner restricted to private repos / a runner group.
# Never attach a self-hosted runner to a public repo (fork PRs could run code here).
set -Eeuo pipefail

if [[ -z ${GH_RUNNER_URL:-} || -z ${GH_RUNNER_TOKEN:-} ]]; then
  echo "GH_RUNNER_URL / GH_RUNNER_TOKEN not set — skipping runner"
  exit 0
fi

dir=/opt/actions-runner
if [[ -f $dir/.runner ]]; then
  echo "runner already configured in $dir"
  exit 0
fi

case $(uname -m) in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
ver=${GH_RUNNER_VERSION:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)}
ver=${ver#v}

install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$dir"
curl -fsSL -o /tmp/actions-runner.tgz \
  "https://github.com/actions/runner/releases/download/v${ver}/actions-runner-linux-${arch}-${ver}.tar.gz"
tar -xzf /tmp/actions-runner.tgz -C "$dir"
rm -f /tmp/actions-runner.tgz
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$dir"
"$dir/bin/installdependencies.sh"

sudo -u "$DEPLOY_USER" "$dir/config.sh" --unattended \
  --url "$GH_RUNNER_URL" --token "$GH_RUNNER_TOKEN" \
  --name "${SERVER_NAME:-$(hostname)}" --labels "infra,${SERVER_NAME:-$(hostname)}" \
  --work _work --replace

(cd "$dir" && ./svc.sh install "$DEPLOY_USER" && ./svc.sh start)
echo "runner OK — labels: infra, ${SERVER_NAME:-$(hostname)}"

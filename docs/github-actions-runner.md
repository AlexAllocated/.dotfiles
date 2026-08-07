# Bumblebee GitHub Actions runner

Tracer provides a two-instance, repository-scoped GitHub Actions runner pool for
trusted Bumblebee build and production-deploy jobs. The NixOS module owns the
service account, toolchain, labels, persistent work directories, and service
lifecycle. A machine-local GitHub token is the only state intentionally kept
outside Nix.

## Security boundary

The runner account can access the rootful Docker socket. That is effectively
root access to Tracer, even though the service does not receive `sudo` access.
Only the private `AlexAllocated/bumblebee` repository and trusted release jobs
may use the `bumblebee-build` label. Never route pull-request or fork-authored
jobs to it.

The runner is registered at repository scope rather than organization scope so
other repositories cannot submit jobs. The workflow keeps `ubuntu-latest` as a
fallback until the repository variable is explicitly changed.

## One-time registration

1. Create a fine-grained personal access token at GitHub. Limit repository
   access to `AlexAllocated/bumblebee` and grant repository **Administration:
   Read and write**. No other repository permission is needed for runner
   registration.
2. Activate the complete Tracer generation.
3. Run `configure-bumblebee-runner-token`. The helper prompts without echo,
   stores the token at `/var/lib/secrets/github-actions/bumblebee` with mode
   `0600`, and starts both `github-runner-bumblebee-tracer-*.service` units.
4. Verify the runner is idle and connected:

   ```bash
   systemctl status 'github-runner-bumblebee-tracer-*.service'
   journalctl -u 'github-runner-bumblebee-tracer-*.service' -n 100
   ```

5. In the Bumblebee repository settings, add the Actions repository variable
   `BUMBLEBEE_BUILD_RUNNER=bumblebee-build`. Clearing the variable immediately
   returns build/deploy jobs to `ubuntu-latest`.

## Operational notes

- Each runner handles one job at a time. Two instances preserve deploy-graph
  parallelism while sharing one Docker daemon, its layer cache, 32 logical CPU
  threads, and the host's 60 GiB of memory.
- The runner work directory persists between jobs for tool downloads and is
  cleaned when the service restarts. Docker's layer cache persists separately.
- NixOS owns the runner package and disables its self-update. A normal dotfiles
  update advances it with the rest of the system generation.
- Rotating the PAT is safe: rerun `configure-bumblebee-runner-token`. The NixOS
  service detects the changed secret and re-registers the same runner name.
- If Tracer is unavailable, clear `BUMBLEBEE_BUILD_RUNNER` before starting a
  deploy so GitHub uses its hosted runner instead of leaving the job queued.

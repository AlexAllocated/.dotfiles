#!/usr/bin/env bash

# Allow startup/hotplug races to settle, but never cycle input devices forever
# when a profile, permission, or hardware error needs attention.
for attempt in 1 2 3; do
	if razer-profile --attempts 3 reapply-profile; then
		exit 0
	fi
	if [[ "$attempt" -lt 3 ]]; then
		printf 'Razer profile application failed (attempt %s/3); retrying in 30 seconds.\n' "$attempt" >&2
		sleep 30
	fi
done

printf '%s\n' 'Razer profile application failed after 3 attempts; stopping automatic retries. See this service journal for the error.' >&2
exit 1

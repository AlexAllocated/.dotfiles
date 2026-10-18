{ libxrandr, xorg-server }:
libxrandr.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ../patches/libxrandr-hotplug-output-query.patch ];
  doCheck = true;
  nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ xorg-server ];
  postCheck = (old.postCheck or "") + ''
    		$CC ${../tests/xrandr-hotplug-query.c} -o hotplug-query \
    			-Iinclude -Lsrc/.libs -Wl,-rpath,"$PWD/src/.libs" -lXrandr -lX11
    		Xvfb :99 -screen 0 800x600x24 -nolisten tcp >xvfb.log 2>&1 &
    		query_xvfb_pid=$!
    		trap 'kill "$query_xvfb_pid" 2>/dev/null || true' EXIT
    		export DISPLAY=:99
    		for query_attempt in $(seq 1 50); do
    			test -S /tmp/.X11-unix/X99 && break
    			sleep 0.1
    		done
    		./hotplug-query
    		kill "$query_xvfb_pid"
    		wait "$query_xvfb_pid" || true
    		trap - EXIT
    	'';
})

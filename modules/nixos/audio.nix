{
  pkgs,
  ...
}:
let
  stereo = [
    "FL"
    "FR"
  ];

  surround71 = [
    "FL"
    "FR"
    "FC"
    "LFE"
    "RL"
    "RR"
    "SL"
    "SR"
  ];

  hrtf = "${pkgs.libmysofa}/share/libmysofa/MIT_KEMAR_normal_pinna.sofa";

  mkCopy = channel: {
    type = "builtin";
    name = "copy${channel}";
    label = "copy";
  };

  mkSofa =
    {
      name,
      azimuth,
      elevation ? 0.0,
    }:
    {
      type = "sofa";
      label = "spatializer";
      inherit name;
      config = {
        filename = hrtf;
        # This is PipeWire's recommended gain for the bundled KEMAR data.
        gain = 0.5;
      };
      control = {
        "Azimuth" = azimuth;
        "Elevation" = elevation;
        "Radius" = 3.0;
      };
    };

  mkPlaybackBus = bus: {
    name = "libpipewire-module-loopback";
    flags = [ "nofail" ];
    args = {
      "node.description" = bus.description;
      "audio.channels" = 2;
      "audio.position" = stereo;

      "capture.props" = {
        "node.name" = "creator.bus.${bus.id}";
        "node.description" = bus.description;
        "media.class" = "Audio/Sink";
        "node.virtual" = true;
        "priority.session" = bus.priority or 50;
      };

      "playback.props" = {
        "node.name" = "creator.bus.${bus.id}.playback";
        "node.description" = "${bus.description} to Default Output";
        "node.passive" = true;
        # Bus monitoring follows the physical device selected as the default.
        "state.restore-target" = false;
        "stream.dont-remix" = false;
      };
    };
  };

  gameBus = {
    name = "libpipewire-module-filter-chain";
    flags = [ "nofail" ];
    args = {
      "node.description" = "Game";
      "media.name" = "Game";
      "audio.rate" = 48000;

      "filter.graph" = {
        nodes = [
          (mkCopy "FL")
          (mkCopy "FR")
          (mkCopy "FC")
          (mkCopy "LFE")
          (mkCopy "RL")
          (mkCopy "RR")
          (mkCopy "SL")
          (mkCopy "SR")

          (mkSofa {
            name = "spFL";
            azimuth = 30.0;
          })
          (mkSofa {
            name = "spFR";
            azimuth = 330.0;
          })
          (mkSofa {
            name = "spFC";
            azimuth = 0.0;
          })
          (mkSofa {
            name = "spLFE";
            azimuth = 0.0;
            elevation = -60.0;
          })
          (mkSofa {
            name = "spRL";
            azimuth = 150.0;
          })
          (mkSofa {
            name = "spRR";
            azimuth = 210.0;
          })
          (mkSofa {
            name = "spSL";
            azimuth = 90.0;
          })
          (mkSofa {
            name = "spSR";
            azimuth = 270.0;
          })

          {
            type = "builtin";
            name = "spatialL";
            label = "mixer";
          }
          {
            type = "builtin";
            name = "spatialR";
            label = "mixer";
          }
          {
            type = "builtin";
            name = "dryL";
            label = "mixer";
            control = {
              "Gain 1" = 1.0;
              "Gain 2" = 0.70710678;
              "Gain 3" = 0.5;
              "Gain 4" = 0.70710678;
              "Gain 5" = 0.70710678;
            };
          }
          {
            type = "builtin";
            name = "dryR";
            label = "mixer";
            control = {
              "Gain 1" = 1.0;
              "Gain 2" = 0.70710678;
              "Gain 3" = 0.5;
              "Gain 4" = 0.70710678;
              "Gain 5" = 0.70710678;
            };
          }
          {
            type = "builtin";
            name = "selectL";
            label = "mixer";
            control = {
              "Gain 1" = 0.0;
              "Gain 2" = 1.0;
            };
          }
          {
            type = "builtin";
            name = "selectR";
            label = "mixer";
            control = {
              "Gain 1" = 0.0;
              "Gain 2" = 1.0;
            };
          }
        ];

        links = [
          {
            output = "copyFL:Out";
            input = "spFL:In";
          }
          {
            output = "copyFR:Out";
            input = "spFR:In";
          }
          {
            output = "copyFC:Out";
            input = "spFC:In";
          }
          {
            output = "copyLFE:Out";
            input = "spLFE:In";
          }
          {
            output = "copyRL:Out";
            input = "spRL:In";
          }
          {
            output = "copyRR:Out";
            input = "spRR:In";
          }
          {
            output = "copySL:Out";
            input = "spSL:In";
          }
          {
            output = "copySR:Out";
            input = "spSR:In";
          }

          {
            output = "spFL:Out L";
            input = "spatialL:In 1";
          }
          {
            output = "spFR:Out L";
            input = "spatialL:In 2";
          }
          {
            output = "spFC:Out L";
            input = "spatialL:In 3";
          }
          {
            output = "spLFE:Out L";
            input = "spatialL:In 4";
          }
          {
            output = "spRL:Out L";
            input = "spatialL:In 5";
          }
          {
            output = "spRR:Out L";
            input = "spatialL:In 6";
          }
          {
            output = "spSL:Out L";
            input = "spatialL:In 7";
          }
          {
            output = "spSR:Out L";
            input = "spatialL:In 8";
          }
          {
            output = "spFL:Out R";
            input = "spatialR:In 1";
          }
          {
            output = "spFR:Out R";
            input = "spatialR:In 2";
          }
          {
            output = "spFC:Out R";
            input = "spatialR:In 3";
          }
          {
            output = "spLFE:Out R";
            input = "spatialR:In 4";
          }
          {
            output = "spRL:Out R";
            input = "spatialR:In 5";
          }
          {
            output = "spRR:Out R";
            input = "spatialR:In 6";
          }
          {
            output = "spSL:Out R";
            input = "spatialR:In 7";
          }
          {
            output = "spSR:Out R";
            input = "spatialR:In 8";
          }

          {
            output = "copyFL:Out";
            input = "dryL:In 1";
          }
          {
            output = "copyFC:Out";
            input = "dryL:In 2";
          }
          {
            output = "copyLFE:Out";
            input = "dryL:In 3";
          }
          {
            output = "copyRL:Out";
            input = "dryL:In 4";
          }
          {
            output = "copySL:Out";
            input = "dryL:In 5";
          }
          {
            output = "copyFR:Out";
            input = "dryR:In 1";
          }
          {
            output = "copyFC:Out";
            input = "dryR:In 2";
          }
          {
            output = "copyLFE:Out";
            input = "dryR:In 3";
          }
          {
            output = "copyRR:Out";
            input = "dryR:In 4";
          }
          {
            output = "copySR:Out";
            input = "dryR:In 5";
          }

          {
            output = "spatialL:Out";
            input = "selectL:In 1";
          }
          {
            output = "dryL:Out";
            input = "selectL:In 2";
          }
          {
            output = "spatialR:Out";
            input = "selectR:In 1";
          }
          {
            output = "dryR:Out";
            input = "selectR:In 2";
          }
        ];

        inputs = [
          "copyFL:In"
          "copyFR:In"
          "copyFC:In"
          "copyLFE:In"
          "copyRL:In"
          "copyRR:In"
          "copySL:In"
          "copySR:In"
        ];
        outputs = [
          "selectL:Out"
          "selectR:Out"
        ];
      };

      "capture.props" = {
        "node.name" = "creator.bus.game";
        "node.description" = "Game";
        "media.class" = "Audio/Sink";
        "audio.channels" = 8;
        "audio.position" = surround71;
        "node.virtual" = true;
        "priority.session" = 100;
      };

      "playback.props" = {
        "node.name" = "creator.bus.game.playback";
        "node.description" = "Game to Default Output";
        "audio.channels" = 2;
        "audio.position" = stereo;
        "node.passive" = true;
        "state.restore-target" = false;
        "stream.dont-remix" = false;
      };
    };
  };

  musicBus = {
    name = "libpipewire-module-filter-chain";
    flags = [ "nofail" ];
    args = {
      "node.description" = "Music";
      "media.name" = "Music";
      "audio.rate" = 48000;

      "filter.graph" = {
        nodes = [
          (mkCopy "FL")
          (mkCopy "FR")
          (mkSofa {
            name = "spFL";
            azimuth = 30.0;
          })
          (mkSofa {
            name = "spFR";
            azimuth = 330.0;
          })
          {
            type = "builtin";
            name = "spatialL";
            label = "mixer";
          }
          {
            type = "builtin";
            name = "spatialR";
            label = "mixer";
          }
          {
            type = "builtin";
            name = "selectL";
            label = "mixer";
            control = {
              "Gain 1" = 0.0;
              "Gain 2" = 1.0;
            };
          }
          {
            type = "builtin";
            name = "selectR";
            label = "mixer";
            control = {
              "Gain 1" = 0.0;
              "Gain 2" = 1.0;
            };
          }
        ];

        links = [
          {
            output = "copyFL:Out";
            input = "spFL:In";
          }
          {
            output = "copyFR:Out";
            input = "spFR:In";
          }
          {
            output = "spFL:Out L";
            input = "spatialL:In 1";
          }
          {
            output = "spFR:Out L";
            input = "spatialL:In 2";
          }
          {
            output = "spFL:Out R";
            input = "spatialR:In 1";
          }
          {
            output = "spFR:Out R";
            input = "spatialR:In 2";
          }
          {
            output = "spatialL:Out";
            input = "selectL:In 1";
          }
          {
            output = "copyFL:Out";
            input = "selectL:In 2";
          }
          {
            output = "spatialR:Out";
            input = "selectR:In 1";
          }
          {
            output = "copyFR:Out";
            input = "selectR:In 2";
          }
        ];

        inputs = [
          "copyFL:In"
          "copyFR:In"
        ];
        outputs = [
          "selectL:Out"
          "selectR:Out"
        ];
      };

      "capture.props" = {
        "node.name" = "creator.bus.music";
        "node.description" = "Music";
        "media.class" = "Audio/Sink";
        "audio.channels" = 2;
        "audio.position" = stereo;
        "node.virtual" = true;
        "priority.session" = 50;
      };

      "playback.props" = {
        "node.name" = "creator.bus.music.playback";
        "node.description" = "Music to Default Output";
        "audio.channels" = 2;
        "audio.position" = stereo;
        "node.passive" = true;
        "state.restore-target" = false;
        "stream.dont-remix" = false;
      };
    };
  };

  spatialAudioControl = pkgs.writeShellApplication {
    name = "spatial-audio";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.pipewire
    ];
    text = ''
      metadata_value() {
        sed -n "s/.*key:'$1' value:'\\([^']*\\)'.*/\\1/p" | tail -n 1
      }

      show_status() {
        snapshot="$(pw-metadata -n default 2>/dev/null)"
        mode="$(printf '%s\n' "$snapshot" | metadata_value creator.spatial.mode)"
        active="$(printf '%s\n' "$snapshot" | metadata_value creator.spatial.active)"
        output="$(printf '%s\n' "$snapshot" | metadata_value creator.spatial.output)"
        printf 'mode: %s\nactive: %s\noutput: %s\n' \
          "''${mode:-unknown}" "''${active:-unknown}" "''${output:-unknown}"
      }

      case "''${1:-status}" in
        auto|on|off)
          pw-metadata -n default 0 creator.spatial.mode "$1" Spa:String >/dev/null
          sleep 0.1
          show_status
          ;;
        status)
          show_status
          ;;
        *)
          printf 'usage: spatial-audio {auto|on|off|status}\n' >&2
          exit 2
          ;;
      esac
    '';
  };

  cleanMic = {
    name = "libpipewire-module-filter-chain";
    flags = [ "nofail" ];
    args = {
      "node.description" = "Clean Mic";
      "media.name" = "Clean Mic";
      "audio.rate" = 48000;

      "filter.graph" = {
        nodes = [
          {
            type = "ladspa";
            name = "deepfilter";
            plugin = "libdeep_filter_ladspa";
            label = "deep_filter_mono";
            # A medium limit removes room/computer noise without making speech
            # sound unnaturally gated. This is the one knob worth tuning later.
            control."Attenuation Limit (dB)" = 24.0;
          }
        ];
        inputs = [ "deepfilter:Audio In" ];
        outputs = [ "deepfilter:Audio Out" ];
      };

      # The Yeti presents duplicate stereo capture channels. Process only FL
      # and expose one proper mono communications source.
      "capture.props" = {
        "node.name" = "creator.filter.clean-mic.capture";
        "target.object" = "creator.hardware.blue-yeti.mic";
        "audio.channels" = 1;
        "audio.position" = [ "FL" ];
        "stream.dont-remix" = true;
        "node.passive" = true;
        "node.dont-fallback" = true;
      };

      "playback.props" = {
        "node.name" = "creator.mic.clean";
        "node.description" = "Clean Mic";
        "media.class" = "Audio/Source";
        "audio.channels" = 1;
        "audio.position" = [ "MONO" ];
        "node.virtual" = true;
        "priority.session" = 3000;
      };
    };
  };

  # Select this source in Discord only when friends should hear the microphone
  # plus Game and Music. Comms is intentionally excluded to prevent echo.
  chatMix = {
    name = "libpipewire-module-loopback";
    flags = [ "nofail" ];
    args = {
      "node.description" = "Chat Mix";
      "audio.channels" = 2;
      "audio.position" = stereo;

      "capture.props" = {
        "node.name" = "creator.bus.chat";
        "node.description" = "Chat Mix Input";
        "media.class" = "Audio/Sink";
        "node.virtual" = true;
        "priority.session" = 50;
      };

      "playback.props" = {
        "node.name" = "creator.mic.chat";
        "node.description" = "Chat Mix";
        "media.class" = "Audio/Source";
        "node.virtual" = true;
        "priority.session" = 50;
      };
    };
  };

  mkChatRoute =
    {
      id,
      source,
      captureSink ? false,
      mono ? false,
      remixCapture ? false,
    }:
    {
      name = "libpipewire-module-loopback";
      flags = [ "nofail" ];
      args = {
        "node.description" = "Chat route ${id}";
        "audio.position" = if mono then [ "MONO" ] else stereo;

        "capture.props" = {
          "node.name" = "creator.route.chat-${id}.capture";
          "target.object" = source;
          "node.passive" = true;
          "node.dont-fallback" = true;
          "stream.dont-remix" = !remixCapture;
        }
        // (
          if captureSink then
            {
              "stream.capture.sink" = true;
            }
          else
            { }
        );

        "playback.props" = {
          "node.name" = "creator.route.chat-${id}.playback";
          "target.object" = "creator.bus.chat";
          "node.passive" = true;
          "node.dont-fallback" = true;
          # Upmix the mono microphone into the stereo chat bus.
          "stream.dont-remix" = false;
        };
      };
    };

  chatRoutes = [
    (mkChatRoute {
      id = "clean-mic";
      source = "creator.mic.clean";
      mono = true;
    })
    (mkChatRoute {
      id = "game";
      source = "creator.bus.game";
      captureSink = true;
      # Game advertises 7.1 so the stereo chat source needs a downmix.
      remixCapture = true;
    })
    (mkChatRoute {
      id = "music";
      source = "creator.bus.music";
      captureSink = true;
    })
  ];
in
{
  environment.systemPackages = [ spatialAudioControl ];

  # Give volatile USB ALSA nodes stable, serial-free names for the native graph.
  services.pipewire.wireplumber.extraConfig."51-creator-hardware-aliases" = {
    "monitor.alsa.rules" = [
      {
        matches = [
          {
            "node.name" = "~alsa_input[.]usb-Generic_Blue_Microphones_LT_.*-00[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.blue-yeti.mic";
          "node.description" = "Blue Yeti Microphone";
          "node.nick" = "Blue Yeti Microphone";
        };
      }
      {
        matches = [
          {
            "node.name" = "~alsa_output[.]usb-Generic_Blue_Microphones_LT_.*-00[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.blue-yeti.output";
          "node.description" = "Blue Yeti Headphones";
          "node.nick" = "Blue Yeti Headphones";
        };
      }
      {
        matches = [
          {
            "node.name" = "~alsa_output[.]usb-Generic_TX-Hifi_Type_C_Audio-.*[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.tx-hifi.output";
          "node.description" = "TX-Hifi Headphones";
          "node.nick" = "TX-Hifi Headphones";
        };
      }
      {
        matches = [
          {
            "node.name" = "~alsa_output[.]usb-ACTIONS_Pebble_V3-.*[.]analog-stereo";
          }
        ];
        actions.update-props = {
          "node.name" = "creator.hardware.pebble-v3.output";
          "node.description" = "Pebble V3 Speakers";
          "node.nick" = "Pebble V3 Speakers";
        };
      }
    ];
  };

  # Keep spatial processing automatic without inserting another routing layer:
  # it follows the selected physical default and is wet only for headphones.
  services.pipewire.wireplumber.extraScripts."creator/spatial-policy.lua" = ''
    local log = Log.open_topic ("creator-spatial")
    local state = State ("creator-spatial")
    local state_table = state:load ()
    local mode = state_table ["mode"] or "auto"
    if mode ~= "auto" and mode ~= "on" and mode ~= "off" then
      mode = "auto"
    end

    local function lookup_node (nodes, name)
      if not name then
        return nil
      end
      return nodes:lookup {
        Constraint { "node.name", "=", name, type = "pw" }
      }
    end

    local function get_default_metadata (source)
      local metadata = source:call ("get-object-manager", "metadata")
      return metadata:lookup {
        Constraint { "metadata.name", "=", "default" }
      }
    end

    local function parse_default_name (value)
      if not value then
        return nil
      end

      local ok, parsed = pcall (function ()
        return Json.Raw (value):parse ()
      end)
      if not ok or not parsed then
        return nil
      end
      return parsed ["name"]
    end

    local function is_headphone (node)
      if not node then
        return false
      end

      local props = node.properties
      local name = props ["node.name"] or ""
      local form_factor = props ["device.form-factor"] or
          props ["device.form_factor"] or ""

      return name == "creator.hardware.blue-yeti.output" or
          name == "creator.hardware.tx-hifi.output" or
          name:match ("^bluez_output[.]") ~= nil or
          form_factor == "headphones" or
          form_factor == "headset"
    end

    local function publish (metadata, key, value)
      if metadata:find (0, key) ~= value then
        metadata:set (0, key, "Spa:String", value)
      end
    end

    local function set_filter_enabled (node, enabled)
      if not node then
        return
      end

      local wet = enabled and 1.0 or 0.0
      local dry = enabled and 0.0 or 1.0
      local param = Pod.Object {
        "Spa:Pod:Object:Param:Props", "Props",
        params = Pod.Struct {
          "selectL:Gain 1", wet,
          "selectL:Gain 2", dry,
          "selectR:Gain 1", wet,
          "selectR:Gain 2", dry,
        }
      }
      node:set_param ("Props", param)
    end

    local function apply_spatial_mode (source)
      local metadata = get_default_metadata (source)
      if not metadata then
        return
      end

      local nodes = source:call ("get-object-manager", "node")
      local output_name =
          parse_default_name (metadata:find (0, "default.audio.sink"))
      local output = lookup_node (nodes, output_name)
      local enabled = mode == "on" or
          (mode == "auto" and is_headphone (output))

      set_filter_enabled (lookup_node (nodes, "creator.bus.game"), enabled)
      set_filter_enabled (lookup_node (nodes, "creator.bus.music"), enabled)

      publish (metadata, "creator.spatial.mode", mode)
      publish (metadata, "creator.spatial.active", enabled and "on" or "off")
      publish (metadata, "creator.spatial.output", output_name or "unknown")
      log:info ("spatial mode " .. mode .. ", active " ..
          (enabled and "on" or "off") .. ", output " ..
          (output_name or "unknown"))
    end

    SimpleEventHook {
      name = "creator-spatial/apply-on-metadata-added",
      after = "default-nodes/metadata-added",
      interests = {
        EventInterest {
          Constraint { "event.type", "=", "metadata-added" },
          Constraint { "metadata.name", "=", "default" },
        },
      },
      execute = function (event)
        apply_spatial_mode (event:get_source ())
      end
    }:register ()

    SimpleEventHook {
      name = "creator-spatial/apply-on-default-changed",
      interests = {
        EventInterest {
          Constraint { "event.type", "=", "metadata-changed" },
          Constraint { "metadata.name", "=", "default" },
          Constraint { "event.subject.key", "=", "default.audio.sink" },
        },
      },
      execute = function (event)
        apply_spatial_mode (event:get_source ())
      end
    }:register ()

    SimpleEventHook {
      name = "creator-spatial/set-mode",
      interests = {
        EventInterest {
          Constraint { "event.type", "=", "metadata-changed" },
          Constraint { "metadata.name", "=", "default" },
          Constraint { "event.subject.key", "=", "creator.spatial.mode" },
        },
      },
      execute = function (event)
        local props = event:get_properties ()
        local requested = props ["event.subject.value"]
        if requested ~= "auto" and requested ~= "on" and requested ~= "off" then
          local metadata = get_default_metadata (event:get_source ())
          if metadata then
            publish (metadata, "creator.spatial.mode", mode)
          end
          return
        end

        if mode ~= requested then
          mode = requested
          state_table ["mode"] = mode
          state:save_after_timeout (state_table)
        end
        apply_spatial_mode (event:get_source ())
      end
    }:register ()

    SimpleEventHook {
      name = "creator-spatial/apply-on-sink-changed",
      interests = {
        EventInterest {
          Constraint { "event.type", "c", "node-added", "node-removed" },
          Constraint { "media.class", "=", "Audio/Sink" },
        },
      },
      execute = function (event)
        apply_spatial_mode (event:get_source ())
      end
    }:register ()

    -- Filter-chain controls become writable when a bus starts processing.
    -- Reapply the selected mode at that transition so idle buses start wet or
    -- dry correctly on their very first audio stream.
    SimpleEventHook {
      name = "creator-spatial/apply-on-filter-running",
      interests = {
        EventInterest {
          Constraint { "event.type", "=", "node-state-changed" },
          Constraint { "node.name", "=", "creator.bus.game" },
        },
        EventInterest {
          Constraint { "event.type", "=", "node-state-changed" },
          Constraint { "node.name", "=", "creator.bus.music" },
        },
      },
      execute = function (event)
        local new_state =
            event:get_properties () ["event.subject.new-state"]
        if new_state == "running" then
          apply_spatial_mode (event:get_source ())
        end
      end
    }:register ()
  '';

  services.pipewire.wireplumber.extraConfig."90-creator-spatial-policy" = {
    "wireplumber.components" = [
      {
        name = "creator/spatial-policy.lua";
        type = "script/lua";
        # Register the hooks before WirePlumber starts its event source so the
        # initial default-device events cannot race policy startup.
        provides = "hooks.creator-spatial-policy";
      }
    ];
    "wireplumber.profiles".main."hooks.creator-spatial-policy" = "required";
  };

  services.pipewire = {
    extraLadspaPackages = [ pkgs.deepfilternet ];

    extraConfig.pipewire."90-creator-audio" = {
      "context.modules" = [
        gameBus
        musicBus
        (mkPlaybackBus {
          id = "comms";
          description = "Comms";
          priority = 50;
        })
        cleanMic
        chatMix
      ]
      ++ chatRoutes;
    };

    # Only known communications and music clients enter a bus automatically.
    # Everything else follows the selected physical default output directly.
    extraConfig.pipewire-pulse."91-creator-audio-routing" = {
      "stream.rules" = [
        {
          matches = [
            {
              "application.process.binary" = ".Discord-wrapped";
              "media.class" = "Stream/Output/Audio";
            }
            {
              "application.name" = "Discord";
              "media.class" = "Stream/Output/Audio";
            }
          ];
          actions.update-props."target.object" = "creator.bus.comms";
        }
        {
          matches = [
            {
              "application.name" = "~.*(Spotify|spotify|Cider|cider|Feishin|feishin|ncspot|YouTube Music).*";
              "media.class" = "Stream/Output/Audio";
            }
            {
              "application.process.binary" = "~.*(spotify|cider|feishin|ncspot).*";
              "media.class" = "Stream/Output/Audio";
            }
          ];
          actions.update-props."target.object" = "creator.bus.music";
        }
        {
          matches = [
            {
              "application.process.binary" = ".Discord-wrapped";
              "media.class" = "Stream/Input/Audio";
            }
            {
              "application.name" = "Discord";
              "media.class" = "Stream/Input/Audio";
            }
          ];
          actions.update-props."target.object" = "creator.mic.clean";
        }
      ];
    };
  };
}

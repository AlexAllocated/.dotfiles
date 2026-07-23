{
  pkgs,
  ...
}:
let
  stereo = [
    "FL"
    "FR"
  ];

  playbackBuses = [
    {
      id = "game";
      description = "Game";
    }
    {
      id = "music";
      description = "Music";
    }
    {
      id = "comms";
      description = "Comms";
    }
  ];

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
        # Keep the real output selected in Noctalia as the system default.
        "priority.session" = 100;
      };

      # No fixed target: WirePlumber follows whichever physical output is
      # selected in Noctalia, making that device the Voicemeeter-style A1.
      "playback.props" = {
        "node.name" = "creator.bus.${bus.id}.playback";
        "node.description" = "${bus.description} to Main Output";
        "node.passive" = true;
        "stream.dont-remix" = false;
      };
    };
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
          "stream.dont-remix" = true;
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
    })
    (mkChatRoute {
      id = "music";
      source = "creator.bus.music";
      captureSink = true;
    })
  ];
in
{
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

  services.pipewire = {
    extraLadspaPackages = [ pkgs.deepfilternet ];

    extraConfig.pipewire."90-creator-audio" = {
      "context.modules" =
        (map mkPlaybackBus playbackBuses)
        ++ [
          cleanMic
          chatMix
        ]
        ++ chatRoutes;
    };

    # Pulse clients enter Game unless a more specific rule assigns them to
    # Comms or Music. Physical output selection remains independent.
    extraConfig.pipewire-pulse."91-creator-audio-routing" = {
      "stream.rules" = [
        {
          matches = [
            {
              "media.class" = "Stream/Output/Audio";
            }
          ];
          actions.update-props."target.object" = "creator.bus.game";
        }
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

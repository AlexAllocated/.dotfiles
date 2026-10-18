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

in
{
  inherit gameBus musicBus;
}

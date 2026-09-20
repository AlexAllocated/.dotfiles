{ ... }:
{
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

  services.pipewire.wireplumber.extraConfig."52-creator-bluetooth-headsets" = {
    "wireplumber.settings" = {
      "bluetooth.autoswitch-to-headset-profile" = true;
      "bluetooth.use-persistent-storage" = true;
    };
    "monitor.bluez.properties" = {
      "bluez5.enable-msbc" = true;
    };
  };

}
